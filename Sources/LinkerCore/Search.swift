import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A live lookup run from the picker. Results are never inserted without asking.
public protocol LiveSearch: Sendable {
    /// `context` is the paragraph around the selection, when known; only rankers that need it receive it.
    func search(_ query: String, context: String?) async throws -> [Candidate]
}

// MARK: The user's own search endpoint

/// Any HTTP endpoint that answers `GET <template with {query}>` with a link list (same JSON as link lists,
/// or `{"results": [...]}`), optionally with a bearer token. This is how a team plugs in its own CRM or wiki.
public struct SearchEndpoint: LiveSearch {
    public let name: String
    public let template: String
    public let token: String?

    public init(name: String, template: String, token: String?) {
        self.name = name
        self.template = template
        self.token = token
    }

    public func search(_ query: String, context: String?) async throws -> [Candidate] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "=", "+", "?", "#"])) ?? query
        let filled = template.contains("{query}") ? template.replacingOccurrences(of: "{query}", with: q) : template + q
        guard let url = URL(string: filled) else { throw SourceError("\(name): invalid search URL") }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var data = try await HTTP.data(req)
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let r = o["results"] {
            data = try JSONSerialization.data(withJSONObject: r)
        }
        return try LinkListParser.parse(data).compactMap { r in
            guard let u = URL.lenient(r.url) else { return nil }
            return Candidate(title: r.name, url: u, subtitle: r.subtitle, kind: r.kind ?? WebResult.kind(for: u),
                             source: .search, badge: name)
        }
    }
}

// MARK: Web search

public enum WebProvider: String, Codable, CaseIterable, Sendable {
    case claude, exa, brave

    public var label: String {
        switch self {
        case .claude: "Claude"
        case .exa: "Exa"
        case .brave: "Brave Search"
        }
    }

    public var keyLabel: String {
        switch self {
        case .claude: "Anthropic API key"
        case .exa: "Exa API key"
        case .brave: "Brave Search API key"
        }
    }

    public var keyURL: URL {
        switch self {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .exa: URL(string: "https://dashboard.exa.ai/api-keys")!
        case .brave: URL(string: "https://api-dashboard.search.brave.com/app/keys")!
        }
    }
}

enum WebResult {
    /// A LinkedIn profile is a person, a site's root page a company, anything else a post or page.
    static func kind(for url: URL) -> EntityKind {
        if url.host?.hasSuffix("linkedin.com") == true, url.path.hasPrefix("/in/") { return .person }
        if url.path.isEmpty || url.path == "/" { return .company }
        return .post
    }
}

/// Web search with the user's own API key. Sends only the selected text, never the paragraph.
/// For text that looks like a person's name it also searches LinkedIn profiles.
public struct WebSearch: LiveSearch {
    public let provider: WebProvider
    public let apiKey: String
    public let ranker: ClaudeRanker?

    public init(provider: WebProvider, apiKey: String, ranker: ClaudeRanker? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.ranker = ranker
    }

    public func search(_ query: String, context: String?) async throws -> [Candidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        if provider == .claude { return try await ClaudeWebSearch(apiKey: apiKey).search(q, context: context) }
        async let general = run(q, linkedIn: false)
        async let people = Self.looksLikePersonName(q) ? (try? await run(q, linkedIn: true)) ?? [] : []
        let merged = Resolver.unique(try await general + people)
        guard let ranker, merged.count > 1 else { return merged }
        return await ranker.rank(merged, for: q, context: context)
    }

    /// Two to four capitalized words, letters only: "Ada Lovelace", "Jean-Luc Picard".
    public static func looksLikePersonName(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard (2...4).contains(words.count) else { return false }
        return words.allSatisfy { w in
            guard let f = w.first, f.isUppercase else { return false }
            return w.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }
        }
    }

    private func run(_ q: String, linkedIn: Bool) async throws -> [Candidate] {
        switch provider {
        case .claude: return []
        case .exa: return try await exa(q, linkedIn: linkedIn)
        case .brave: return try await brave(q, linkedIn: linkedIn)
        }
    }

    private func exa(_ q: String, linkedIn: Bool) async throws -> [Candidate] {
        var req = URLRequest(url: URL(string: "https://api.exa.ai/search")!, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        var body: [String: Any] = ["query": q, "numResults": linkedIn ? 3 : 6, "type": "auto"]
        if linkedIn { body["includeDomains"] = ["linkedin.com"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let results = (try await HTTP.json(req) as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return Self.candidates(results.map { ($0["title"] as? String, $0["url"] as? String, $0["author"] as? String,
                                              ($0["publishedDate"] as? String).flatMap(FeedSource.parseDate)) },
                               linkedIn: linkedIn)
    }

    private func brave(_ q: String, linkedIn: Bool) async throws -> [Candidate] {
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        c.queryItems = [.init(name: "q", value: linkedIn ? "\(q) site:linkedin.com/in" : q),
                        .init(name: "count", value: linkedIn ? "3" : "6")]
        var req = URLRequest(url: c.url!, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        let web = (try await HTTP.json(req) as? [String: Any])?["web"] as? [String: Any]
        let results = web?["results"] as? [[String: Any]] ?? []
        return Self.candidates(results.map { ($0["title"] as? String, $0["url"] as? String,
                                              ($0["description"] as? String).map(FeedParser.stripTags), nil) },
                               linkedIn: linkedIn)
    }

    static func candidates(_ rows: [(String?, String?, String?, Date?)], linkedIn: Bool) -> [Candidate] {
        rows.compactMap { title, url, subtitle, date in
            guard let u = url.flatMap(URL.init(string:)), u.scheme?.hasPrefix("http") == true else { return nil }
            if linkedIn, WebResult.kind(for: u) != .person { return nil }
            let t = (title?.isEmpty == false ? title! : u.displayHost).trimmingCharacters(in: .whitespacesAndNewlines)
            return Candidate(title: t, url: u, subtitle: subtitle.map { String($0.prefix(140)) },
                             kind: WebResult.kind(for: u), source: .web, date: date)
        }
    }
}

// MARK: Web search by Claude

/// Claude searches the web itself (Anthropic's web search tool) and picks the best link targets, so one Anthropic key
/// is enough. Sends the selection and its paragraph to Anthropic; Claude chooses the search queries.
public struct ClaudeWebSearch: Sendable {
    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Claude Haiku with the basic search tool first; if the API rejects that pairing, Claude Sonnet with the current tool.
    static let attempts: [(model: String, tool: String)] = [
        ("claude-haiku-5-5", "web_search_20250305"),
        ("claude-sonnet-5-5", "web_search_20260209"),
    ]

    public func search(_ selection: String, context: String?) async throws -> [Candidate] {
        var lastError: Error = SourceError("Claude: no result")
        for a in Self.attempts {
            do { return try await run(selection, context: context, model: a.model, tool: a.tool) }
            catch let e as RejectedRequest { lastError = e }
        }
        throw lastError
    }

    struct RejectedRequest: Error, CustomStringConvertible { let description: String }

    func run(_ selection: String, context: String?, model: String, tool: String) async throws -> [Candidate] {
        let prompt = """
        Someone selected the text "\(selection)" in a document and wants to turn it into a hyperlink.
        \(context.map { "The paragraph around it:\n\"\"\"\n\($0.prefix(1500))\n\"\"\"\n" } ?? "")
        Search the web for the page this text should link to. Prefer a company's official homepage, a person's LinkedIn \
        profile, and for a post or article the article itself. Make sure it is the same person, company or article the \
        paragraph means, not a namesake.

        Reply with only JSON, no other text: {"links": [{"title": "...", "url": "..."}]}, best first, at most 5.
        """
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "output_config": ["effort": "low"],
            "tools": [["type": tool, "name": "web_search", "max_uses": 2]],
            "messages": [["role": "user", "content": prompt]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await HTTP.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code == 400 {
            let msg = (reply["error"] as? [String: Any])?["message"] as? String ?? "HTTP 400"
            throw RejectedRequest(description: "Claude: \(msg)")
        }
        guard (200..<300).contains(code) else { throw SourceError("Claude returned HTTP \(code)") }
        return Self.candidates(from: reply)
    }

    /// The links Claude chose; if its answer can't be read, the raw search results.
    public static func candidates(from reply: [String: Any]) -> [Candidate] {
        let blocks = reply["content"] as? [[String: Any]] ?? []
        var raw: [Candidate] = []
        for b in blocks where b["type"] as? String == "web_search_tool_result" {
            for r in b["content"] as? [[String: Any]] ?? [] {
                guard let u = (r["url"] as? String).flatMap(URL.init(string:)) else { continue }
                raw.append(Candidate(title: r["title"] as? String ?? u.displayHost, url: u, kind: WebResult.kind(for: u), source: .web))
            }
        }
        var chosen: [Candidate] = []
        if reply["stop_reason"] as? String != "refusal",
           let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
           let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
           let links = json["links"] as? [[String: Any]] {
            chosen = links.compactMap { l in
                guard let u = (l["url"] as? String).flatMap(URL.lenient) else { return nil }
                let title = (l["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? u.displayHost
                return Candidate(title: title, url: u, kind: WebResult.kind(for: u), source: .web, badge: "Claude")
            }
        }
        return Resolver.unique(chosen.isEmpty ? raw : chosen)
    }
}

// MARK: Ranking with Claude

/// Orders web results by how well they fit the selected text in its paragraph, and drops results about
/// a different person or company with the same name. Uses the user's own Anthropic API key.
/// Sends the selection, its paragraph and the result titles/URLs; nothing else from the document.
public struct ClaudeRanker: Sendable {
    public let apiKey: String
    public let model: String

    public init(apiKey: String, model: String = "claude-haiku-5-5") {
        self.apiKey = apiKey
        self.model = model
    }

    /// Falls back to the original order on any error, so ranking can only help.
    public func rank(_ items: [Candidate], for selection: String, context: String?) async -> [Candidate] {
        guard let order = try? await order(items, selection: selection, context: context) else { return items }
        let picked = order.filter { items.indices.contains($0) }
        var seen = Set<Int>()
        let ranked = picked.filter { seen.insert($0).inserted }.map { items[$0] }
        return ranked.isEmpty ? items : ranked
    }

    func order(_ items: [Candidate], selection: String, context: String?) async throws -> [Int] {
        let list = items.enumerated().map { i, c in
            "\(i). \(c.title) — \(c.url.absoluteString)\(c.subtitle.map { " — \($0)" } ?? "")"
        }.joined(separator: "\n")
        let prompt = """
        Someone selected the text "\(selection)" in a document and wants to turn it into a hyperlink.
        \(context.map { "The paragraph around it:\n\"\"\"\n\($0.prefix(1500))\n\"\"\"\n" } ?? "")
        Web search results:
        \(list)

        Return the numbers of the results that are a good link target for the selected text in this context, best first. \
        Leave out results about a different person, company or article that merely shares the name. Prefer a company's \
        official homepage, a person's LinkedIn profile, and for a post or article the article itself.
        """
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": [
                    "type": "object",
                    "properties": ["best": ["type": "array", "items": ["type": "integer"]]],
                    "required": ["best"],
                    "additionalProperties": false,
                ]],
            ],
            "messages": [["role": "user", "content": prompt]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let reply = try await HTTP.json(req) as? [String: Any] else { throw SourceError("Claude: no reply") }
        if reply["stop_reason"] as? String == "refusal" { throw SourceError("Claude declined to rank") }
        let text = (reply["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let best = json["best"] as? [Int] else { throw SourceError("Claude: unexpected reply") }
        return best
    }
}
