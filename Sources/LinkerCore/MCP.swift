import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Any MCP server (streamable HTTP transport) as a source: a "sync tool" whose results are indexed like a link list,
// and "search tools" queried live from the picker. Results are read generically: every JSON object with a name and
// a URL becomes a link, so most servers work without a mapping.

// MARK: Sign-in (OAuth authorization code + PKCE, dynamic client registration, loopback redirect)

public enum MCPAuth {
    public static let callbackPort: UInt16 = 47823
    public static let redirectURI = "http://127.0.0.1:47823/callback"

    public struct Tokens: Codable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date
        public var clientId: String
        public var tokenEndpoint: URL
    }

    /// One sign-in attempt: open `authorizeURL`, then hand the redirect back to `finishLogin`.
    public struct Login: Sendable {
        public let authorizeURL: URL
        public let clientId: String
        let resource: URL
        let verifier: String
        let state: String
        let tokenEndpoint: URL
    }

    struct ServerMetadata {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
    }

    /// RFC 9728: the resource names its authorization server; RFC 8414: the server lists its endpoints.
    static func discover(_ resource: URL) async throws -> ServerMetadata {
        let host = "\(resource.scheme ?? "https")://\(resource.host!)\(resource.port.map { ":\($0)" } ?? "")"
        var issuer: URL?
        for path in ["/.well-known/oauth-protected-resource\(resource.path)", "/.well-known/oauth-protected-resource"] {
            if let rm = try? await HTTP.json(URLRequest(url: URL(string: host + path)!)) as? [String: Any],
               let first = (rm["authorization_servers"] as? [String])?.first.flatMap(URL.init(string:)) {
                issuer = first
                break
            }
        }
        let base = issuer ?? URL(string: host)!
        for path in [".well-known/oauth-authorization-server", ".well-known/openid-configuration"] {
            if let m = try? await HTTP.json(URLRequest(url: base.appendingPathComponent(path))) as? [String: Any],
               let auth = (m["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
               let token = (m["token_endpoint"] as? String).flatMap(URL.init(string:)) {
                return ServerMetadata(authorizationEndpoint: auth, tokenEndpoint: token,
                                      registrationEndpoint: (m["registration_endpoint"] as? String).flatMap(URL.init(string:)))
            }
        }
        throw SourceError("\(resource.host ?? "server") doesn't offer OAuth sign-in; use a token instead")
    }

    /// Registers Linker as a client (once; pass the stored id to reuse it) and builds the browser sign-in URL.
    /// `challenge` maps the PKCE verifier to its S256 challenge (CryptoKit lives in the app target).
    public static func startLogin(resource: URL, clientId existing: String?, challenge: (String) -> String) async throws -> Login {
        let meta = try await discover(resource)
        var clientId = existing
        if clientId == nil {
            guard let reg = meta.registrationEndpoint else {
                throw SourceError("\(resource.host ?? "server") doesn't let apps register; use a token instead")
            }
            var req = URLRequest(url: reg)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_name": "Linker",
                "redirect_uris": [redirectURI],
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
            ])
            clientId = (try await HTTP.json(req) as? [String: Any])?["client_id"] as? String
        }
        guard let clientId else { throw SourceError("The sign-in server refused to register Linker") }

        let verifier = randomToken(48)
        let state = randomToken(16)
        var c = URLComponents(url: meta.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: "openid offline_access"),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge(verifier)),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "resource", value: resource.absoluteString),
        ]
        return Login(authorizeURL: c.url!, clientId: clientId, resource: resource, verifier: verifier, state: state,
                     tokenEndpoint: meta.tokenEndpoint)
    }

    /// Exchanges the code from the browser redirect (`/callback?code=…&state=…`) for tokens.
    public static func finishLogin(_ login: Login, callback: URL) async throws -> Tokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        if let error = value("error") { throw SourceError("Sign-in failed: \(value("error_description") ?? error)") }
        guard value("state") == login.state, let code = value("code") else { throw SourceError("Sign-in reply didn't match; try again") }
        let (data, _) = try await HTTP.session.data(for: form(login.tokenEndpoint, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": login.clientId, "code_verifier": login.verifier, "resource": login.resource.absoluteString,
        ]))
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard body["access_token"] != nil else {
            throw SourceError("Sign-in failed: \(body["error_description"] as? String ?? body["error"] as? String ?? "no token")")
        }
        return try tokens(body, clientId: login.clientId, endpoint: login.tokenEndpoint, previous: nil)
    }

    public static func refresh(_ t: Tokens) async throws -> Tokens {
        guard let refreshToken = t.refreshToken else { throw SourceError("Signed out; sign in again in Settings") }
        let (data, resp) = try await HTTP.session.data(for: form(t.tokenEndpoint, [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": t.clientId,
        ]))
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, body["access_token"] != nil else {
            throw SourceError("Sign-in expired; sign in again in Settings")
        }
        return try tokens(body, clientId: t.clientId, endpoint: t.tokenEndpoint, previous: t)
    }

    static func tokens(_ b: [String: Any], clientId: String, endpoint: URL, previous: Tokens?) throws -> Tokens {
        guard let access = b["access_token"] as? String else { throw SourceError("No access token") }
        return Tokens(accessToken: access, refreshToken: (b["refresh_token"] as? String) ?? previous?.refreshToken,
                      expiresAt: Date().addingTimeInterval((b["expires_in"] as? Double) ?? 3600),
                      clientId: clientId, tokenEndpoint: endpoint)
    }

    /// URL-safe random string (PKCE verifier, state).
    static func randomToken(_ bytes: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var g = SystemRandomNumberGenerator()
        return String((0..<(bytes * 4 / 3)).map { _ in chars[Int(g.next(upperBound: UInt(chars.count)))] })
    }

    static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return req
    }
}

// MARK: Client

public enum MCPCredential: Sendable {
    case none
    case token(String)
    case oauth(MCPAuth.Tokens)
}

/// Calls tools over MCP's streamable HTTP transport, refreshing OAuth tokens as needed.
public actor MCPClient {
    public let endpoint: URL
    private var credential: MCPCredential
    private let onTokens: @Sendable (MCPAuth.Tokens) -> Void
    private var sessionId: String?
    private var nextId = 1
    private var schemas: [String: [String: Any]]?

    public init(endpoint: URL, credential: MCPCredential, onTokens: @escaping @Sendable (MCPAuth.Tokens) -> Void = { _ in }) {
        self.endpoint = endpoint
        self.credential = credential
        self.onTokens = onTokens
    }

    var name: String { endpoint.host ?? "MCP server" }

    /// Calls a tool and returns its result parsed as JSON (or the raw text when it isn't JSON).
    public func callTool(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> Any {
        if sessionId == nil { try await initialize() }
        let result: [String: Any]
        do {
            result = try await rpc("tools/call", ["name": tool, "arguments": arguments])
        } catch MCPError.sessionExpired {
            sessionId = nil
            try await initialize()
            result = try await rpc("tools/call", ["name": tool, "arguments": arguments])
        }
        if let structured = result["structuredContent"] { return structured }
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        if result["isError"] as? Bool == true { throw SourceError("\(tool): \(text.prefix(200))") }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? text
    }

    /// The argument a search tool takes its text in: the first required string parameter, else a usual name.
    public func queryArgument(for tool: String) async -> String {
        if schemas == nil, let list = try? await listTools() {
            schemas = Dictionary(list.compactMap { t in (t["name"] as? String).map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
        }
        let schema = schemas?[tool]?["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: [String: Any]] ?? [:]
        let strings = props.filter { $0.value["type"] as? String == "string" }.map(\.key)
        if let req = (schema?["required"] as? [String])?.first(where: strings.contains) { return req }
        return ["query", "q", "search", "name", "text"].first(where: strings.contains) ?? strings.sorted().first ?? "query"
    }

    public func listTools() async throws -> [[String: Any]] {
        if sessionId == nil { try await initialize() }
        return (try await rpc("tools/list", [:]))["tools"] as? [[String: Any]] ?? []
    }

    enum MCPError: Error { case sessionExpired }

    private func initialize() async throws {
        _ = try await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                         "clientInfo": ["name": "Linker", "version": "1.1"]])
        _ = try await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private func authorization(forceRefresh: Bool = false) async throws -> String? {
        switch credential {
        case .none: return nil
        case .token(let t): return "Bearer \(t)"
        case .oauth(var tokens):
            if forceRefresh || tokens.expiresAt.timeIntervalSinceNow < 60 {
                tokens = try await MCPAuth.refresh(tokens)
                credential = .oauth(tokens)
                onTokens(tokens)
            }
            return "Bearer \(tokens.accessToken)"
        }
    }

    private func request(_ body: [String: Any], auth: String?) throws -> URLRequest {
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        if let auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionId { req.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func send(_ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var (data, resp) = try await HTTP.session.data(for: request(body, auth: try await authorization()))
        if (resp as? HTTPURLResponse)?.statusCode == 401, case .oauth = credential {
            (data, resp) = try await HTTP.session.data(for: request(body, auth: try await authorization(forceRefresh: true)))
        }
        guard let http = resp as? HTTPURLResponse else { throw SourceError("No response from \(name)") }
        if http.statusCode == 404, sessionId != nil, body["method"] as? String != "initialize" { throw MCPError.sessionExpired }
        if http.statusCode == 401 { throw SourceError("\(name): not signed in (HTTP 401)") }
        guard (200..<300).contains(http.statusCode) else { throw SourceError("\(name) returned HTTP \(http.statusCode)") }
        if let s = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = s }
        return (data, http)
    }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let (data, http) = try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let messages: [[String: Any]]
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            // Each SSE event carries one JSON-RPC message on its data: lines.
            messages = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                .filter { $0.hasPrefix("data:") }
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(5).utf8)) as? [String: Any] }
        } else {
            messages = [(try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]]
        }
        guard let reply = messages.first(where: { ($0["id"] as? Int) == id }) else {
            throw SourceError("\(name) sent no reply to \(method)")
        }
        if let err = reply["error"] as? [String: Any] { throw SourceError("\(name): \(err["message"] as? String ?? "error")") }
        return reply["result"] as? [String: Any] ?? [:]
    }
}

// MARK: Reading links out of tool results

public enum MCPExtract {
    public struct Link: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let subtitle: String?
    }

    /// Every JSON object (at any depth) with a name and a URL. Keys are matched loosely, so `name`, `title`,
    /// `company.name` or `c.name` all count as names, and `url`, `website`, `homepage` or `linkedin` as URLs.
    public static func links(in json: Any) -> [Link] {
        var out: [Link] = []
        var seen = Set<String>()
        walk(json) { o in
            guard let l = link(from: o), seen.insert(l.name.lowercased() + "|" + l.url.absoluteString).inserted else { return }
            out.append(l)
        }
        return out
    }

    static func walk(_ v: Any, _ visit: ([String: Any]) -> Void) {
        if let o = v as? [String: Any] {
            visit(o)
            for x in o.values { walk(x, visit) }
        } else if let a = v as? [Any] {
            for x in a { walk(x, visit) }
        }
    }

    /// The last part of a key: "c.website" → "website", "company_name" stays.
    static func leaf(_ key: String) -> String {
        String(key.lowercased().split(whereSeparator: { $0 == "." || $0 == "/" }).last ?? "")
    }

    static let urlKeys = ["url", "website", "homepage", "home_page", "linkedin", "linkedin_url", "link", "href", "domain"]
    static let nameKeys = ["name", "full_name", "company_name", "display_name", "title"]
    static let subtitleKeys = ["subtitle", "description", "brief", "headline", "summary", "tagline"]

    static func link(from o: [String: Any]) -> Link? {
        var byLeaf: [String: String] = [:]
        for (k, v) in o {
            if let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { byLeaf[leaf(k)] = byLeaf[leaf(k)] ?? s }
        }
        guard let url = urlKeys.lazy.compactMap({ byLeaf[$0].flatMap(URL.lenient) }).first,
              let nameKey = nameKeys.first(where: { byLeaf[$0] != nil }), var name = byLeaf[nameKey] else { return nil }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Email subjects stored as names ("Fwd: …") aren't link text.
        let lower = name.lowercased()
        if ["re:", "fwd:", "fw:", "aw:", "wg:"].contains(where: lower.hasPrefix) || name.count > 120 { return nil }
        // With a real name, a "title" field is a job title: use it as the subtitle.
        var subtitle = subtitleKeys.lazy.compactMap { byLeaf[$0] }.first
        if nameKey != "title", subtitle == nil { subtitle = byLeaf["title"] }
        return Link(name: name, url: url, subtitle: subtitle.map { String($0.prefix(140)) })
    }

    /// Every query word starts a word of the name: "lovelace" and "ada lov" match "Ada Lovelace", "ada smith" doesn't.
    /// Search tools often return fuzzy matches; these keep the picker to plausible ones.
    public static func nameMatches(_ name: String, query: String) -> Bool {
        let words = Normalize.key(name).split(separator: " ")
        return Normalize.key(query).split(separator: " ").allSatisfy { q in words.contains { $0.hasPrefix(q) } }
    }

    /// A LinkedIn profile only fits if its address contains part of the person's name ("in/ada-lovelace" for Ada
    /// Lovelace); enrichment data sometimes attaches someone else's profile.
    public static func profileFits(_ url: URL, name: String) -> Bool {
        guard url.host?.hasSuffix("linkedin.com") == true, url.path.hasPrefix("/in/") else { return true }
        let slug = Normalize.key(url.lastPathComponent).replacingOccurrences(of: " ", with: "")
        return Normalize.key(name).split(separator: " ").contains { $0.count >= 3 && slug.contains($0) }
    }
}

// MARK: Sources

/// A tool called at every sync (no arguments); its links are indexed like a link list and may be inserted unasked.
public struct MCPSyncSource: EntitySource {
    public let id: String
    public let name: String
    public let client: MCPClient
    public let tool: String
    public var feed: String { "mcp:\(id):\(tool)" }

    public init(id: String, name: String, client: MCPClient, tool: String) {
        self.id = id
        self.name = name
        self.client = client
        self.tool = tool
    }

    public func fetch() async throws -> [Entity] {
        let links = MCPExtract.links(in: try await client.callTool(tool))
        guard !links.isEmpty else { throw SourceError("\(name): \(tool) returned no links") }
        return links.filter { MCPExtract.profileFits($0.url, name: $0.name) }.map { l in
            Entity(id: "\(feed):\(l.name)|\(l.url.absoluteString)", kind: WebResult.kind(for: l.url), source: .list,
                   name: l.name, url: l.url, subtitle: l.subtitle, badge: name)
        }
    }
}

/// Search tools queried live from the picker, all at once. Never inserted without asking.
public struct MCPSearch: LiveSearch {
    public let name: String
    public let client: MCPClient
    public let tools: [String]

    public init(name: String, client: MCPClient, tools: [String]) {
        self.name = name
        self.client = client
        self.tools = tools
    }

    public func search(_ query: String, context: String?) async throws -> [Candidate] {
        guard Normalize.key(query).count >= 3 else { return [] }
        let client = client
        let parts = await withTaskGroup(of: (Int, [MCPExtract.Link]).self) { group in
            for (i, tool) in tools.enumerated() {
                group.addTask {
                    let arg = await client.queryArgument(for: tool)
                    let result = (try? await client.callTool(tool, [arg: query])) ?? [:]
                    return (i, MCPExtract.links(in: result))
                }
            }
            var all: [(Int, [MCPExtract.Link])] = []
            for await p in group { all.append(p) }
            return all.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        let key = Normalize.key(query)
        let found = parts.filter { MCPExtract.nameMatches($0.name, query: query) && MCPExtract.profileFits($0.url, name: $0.name) }
            .map { Candidate(title: $0.name, url: $0.url, subtitle: $0.subtitle, kind: WebResult.kind(for: $0.url),
                             source: .search, badge: name) }
        // Exact name matches first, then the server's own order.
        let ranked = found.enumerated().sorted { a, b in
            let ea = Normalize.key(a.element.title) == key, eb = Normalize.key(b.element.title) == key
            return ea != eb ? ea : a.offset < b.offset
        }.map(\.element)
        return Array(Resolver.unique(ranked).prefix(6))
    }
}
