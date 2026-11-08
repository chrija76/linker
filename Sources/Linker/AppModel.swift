import AppKit
import CryptoKit
import LinkerCore

/// An MCP server the user connected. Tokens live in the keychain under `credentialAccount`.
struct MCPServerConfig: Codable, Identifiable, Hashable {
    enum Auth: String, Codable, CaseIterable { case signIn, token, none }

    var id = UUID().uuidString
    var name: String
    var url: String
    var auth: Auth = .signIn
    /// Comma-separated tools queried live from the picker, e.g. "find_person, find_company".
    var searchTools: String = ""
    /// A tool called at sync whose results are indexed like a link list, e.g. "portfolio". Optional.
    var syncTool: String = ""

    var credentialAccount: String { "mcp-credential:\(id)" }
    var clientIdAccount: String { "mcp-client:\(id)" }
    var endpoint: URL? { URL.lenient(url) }
    var searchToolList: [String] {
        searchTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var syncToolName: String? {
        let t = syncTool.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
    var syncFeed: String? { syncToolName.map { "mcp:\(id):\($0)" } }
}

/// A link list the user added in Settings. Its token, if any, is in the keychain under `tokenAccount`.
struct LinkList: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var location: String
    var kind: EntityKind = .company

    var tokenAccount: String { "list-token:\(id)" }
    var feed: String { "list:\(id)" }
    var isFile: Bool { LinkListSource(id: id, name: name, location: location).fileURL != nil }
}

/// Shared state: the index, the resolver, the user's sources and keys, and sync.
@MainActor
final class AppModel: ObservableObject {
    let supportDir: URL
    let store: Store
    let resolver: Resolver

    @Published var lists: [LinkList] { didSet { save(lists, "lists") } }
    @Published var mcpServers: [MCPServerConfig] {
        didSet { save(mcpServers, "mcpServers"); clients = [:] }
    }
    @Published var feeds: String { didSet { UserDefaults.standard.set(feeds, forKey: "feeds") } }
    @Published var searchName: String { didSet { UserDefaults.standard.set(searchName, forKey: "searchName") } }
    @Published var searchTemplate: String { didSet { UserDefaults.standard.set(searchTemplate, forKey: "searchTemplate") } }
    @Published var webProvider: WebProvider? {
        didSet { UserDefaults.standard.set(webProvider?.rawValue, forKey: "webProvider") }
    }

    @Published private(set) var syncing = false
    @Published private(set) var reports: [SyncReport] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var rememberedCount = 0
    @Published private(set) var postCount = 0
    /// Bumped when keys change so views re-read the keychain.
    @Published private(set) var keysVersion = 0
    @Published private(set) var signingIn: String?
    @Published private(set) var signInError: [String: String] = [:]
    private var signInTask: Task<Void, Never>?
    private var clients: [String: MCPClient] = [:]

    var defaultListFile: URL { supportDir.appendingPathComponent("links.csv") }

    init() {
        supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Linker", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        store = try! Store(path: supportDir.appendingPathComponent("linker.sqlite").path)
        resolver = Resolver(store: store)

        let d = UserDefaults.standard
        lists = d.data(forKey: "lists").flatMap { try? JSONDecoder().decode([LinkList].self, from: $0) } ?? []
        mcpServers = d.data(forKey: "mcpServers").flatMap { try? JSONDecoder().decode([MCPServerConfig].self, from: $0) } ?? []
        feeds = d.string(forKey: "feeds") ?? ""
        searchName = d.string(forKey: "searchName") ?? ""
        searchTemplate = d.string(forKey: "searchTemplate") ?? ""
        webProvider = d.string(forKey: "webProvider").flatMap(WebProvider.init(rawValue:))
        lastSync = store.meta("lastSync").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))

        // First run: one empty list the user can fill in, so there is somewhere to start.
        if d.data(forKey: "lists") == nil {
            if !FileManager.default.fileExists(atPath: defaultListFile.path) {
                try? Data("name,url,aliases,subtitle,kind\n".utf8).write(to: defaultListFile)
            }
            lists = [LinkList(name: "My links", location: defaultListFile.path)]
        }
        refreshCounts()
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    // MARK: Keys

    func secret(_ account: String) -> String { Keychain.get(account) ?? "" }

    func setSecret(_ account: String, _ value: String) {
        Keychain.set(account, value.trimmingCharacters(in: .whitespacesAndNewlines))
        keysVersion += 1
    }

    static let anthropicAccount = "anthropic-key"
    static let searchTokenAccount = "search-token"
    /// Claude search uses the same Anthropic key as ranking.
    static func webKeyAccount(_ p: WebProvider) -> String { p == .claude ? anthropicAccount : "web-key:\(p.rawValue)" }

    // MARK: Sources

    var sources: [any EntitySource] {
        let l: [any EntitySource] = lists.map {
            LinkListSource(id: $0.id, name: $0.name, location: $0.location, token: Keychain.get($0.tokenAccount), defaultKind: $0.kind)
        }
        let m: [any EntitySource] = mcpServers.compactMap { s in
            guard let tool = s.syncToolName, let c = client(for: s) else { return nil }
            return MCPSyncSource(id: s.id, name: s.name, client: c, tool: tool)
        }
        return l + m + feeds.split(whereSeparator: \.isNewline).compactMap { FeedSource(String($0)) }
    }

    // MARK: MCP servers

    /// A client for the server, or nil while it needs a sign-in or token it doesn't have yet.
    func client(for s: MCPServerConfig) -> MCPClient? {
        if let c = clients[s.id] { return c }
        guard let endpoint = s.endpoint else { return nil }
        let credential: MCPCredential
        switch s.auth {
        case .none: credential = .none
        case .token:
            guard let t = Keychain.get(s.credentialAccount), !t.isEmpty else { return nil }
            credential = .token(t)
        case .signIn:
            guard let saved = Keychain.get(s.credentialAccount).flatMap({ try? JSONDecoder().decode(MCPAuth.Tokens.self, from: Data($0.utf8)) })
            else { return nil }
            credential = .oauth(saved)
        }
        let account = s.credentialAccount
        let c = MCPClient(endpoint: endpoint, credential: credential) { refreshed in
            if let data = try? JSONEncoder().encode(refreshed) { Keychain.set(account, String(decoding: data, as: UTF8.self)) }
        }
        clients[s.id] = c
        return c
    }

    func isConnected(_ s: MCPServerConfig) -> Bool {
        s.auth == .none || !(Keychain.get(s.credentialAccount) ?? "").isEmpty
    }

    func setToken(_ s: MCPServerConfig, _ token: String) {
        setSecret(s.credentialAccount, token)
        clients[s.id] = nil
    }

    func signIn(_ s: MCPServerConfig) {
        guard let endpoint = s.endpoint else { signInError[s.id] = "Enter the server's URL first"; return }
        signInTask?.cancel()
        signInError[s.id] = nil
        signingIn = s.id
        signInTask = Task {
            defer { signingIn = nil }
            do {
                let server = try LoopbackServer(port: MCPAuth.callbackPort)
                let login = try await MCPAuth.startLogin(resource: endpoint, clientId: Keychain.get(s.clientIdAccount)) { verifier in
                    Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                }
                Keychain.set(s.clientIdAccount, login.clientId)
                NSWorkspace.shared.open(login.authorizeURL)
                let callback = try await withTimeout(seconds: 300) { try await server.waitForCallback() }
                let tokens = try await MCPAuth.finishLogin(login, callback: callback)
                if let data = try? JSONEncoder().encode(tokens) { Keychain.set(s.credentialAccount, String(decoding: data, as: UTF8.self)) }
                clients[s.id] = nil
                keysVersion += 1
                NSApp.activate()
                sync()
            } catch is CancellationError {
            } catch {
                signInError[s.id] = "\(error)"
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signingIn = nil
    }

    func signOut(_ s: MCPServerConfig) {
        Keychain.set(s.credentialAccount, nil)
        clients[s.id] = nil
        keysVersion += 1
        sync()
    }

    /// Live lookups for the picker: MCP servers, the user's search endpoint and web search, run concurrently.
    var liveSearches: [any LiveSearch] {
        var out: [any LiveSearch] = mcpServers.compactMap { s in
            guard !s.searchToolList.isEmpty, let c = client(for: s) else { return nil }
            return MCPSearch(name: s.name, client: c, tools: s.searchToolList)
        }
        let template = searchTemplate.trimmingCharacters(in: .whitespaces)
        if !template.isEmpty {
            out.append(SearchEndpoint(name: searchName.isEmpty ? "Search" : searchName, template: template,
                                      token: Keychain.get(Self.searchTokenAccount)))
        }
        if let webProvider, let key = Keychain.get(Self.webKeyAccount(webProvider)), !key.isEmpty {
            let anthropic = webProvider == .claude ? nil : Keychain.get(Self.anthropicAccount)
            out.append(WebSearch(provider: webProvider, apiKey: key,
                                 ranker: anthropic.flatMap { $0.isEmpty ? nil : ClaudeRanker(apiKey: $0) }))
        }
        return out
    }

    var liveSearchLabel: String {
        var parts: [String] = mcpServers.filter { !$0.searchToolList.isEmpty && isConnected($0) }.map(\.name)
        if !searchTemplate.isEmpty { parts.append(searchName.isEmpty ? "your search" : searchName) }
        if let webProvider, !(Keychain.get(Self.webKeyAccount(webProvider)) ?? "").isEmpty { parts.append("the web") }
        return parts.isEmpty ? "" : "Searching " + parts.joined(separator: " and ")
    }

    func sync() {
        guard !syncing else { return }
        syncing = true
        let sources = sources
        let store = store
        Task {
            let reports = await Sync.run(sources, into: store)
            // Drop what's left from lists and blogs the user has removed.
            let live = Set(sources.map(\.feed))
            for f in store.feeds() where !live.contains(f) { try? store.replace(feed: f, with: []) }
            store.setMeta("lastSync", String(Date().timeIntervalSince1970))
            self.reports = reports
            self.lastSync = Date()
            self.syncing = false
            self.refreshCounts()
        }
    }

    /// Syncs when the last sync is older than `maxAge` (default: a day).
    func syncIfStale(maxAge: TimeInterval = 24 * 3600) {
        if lastSync.map({ Date().timeIntervalSince($0) > maxAge }) ?? true { sync() }
    }

    func error(for feed: String) -> String? { reports.first { $0.feed == feed }?.error }

    func count(feed: String) -> Int { store.count(feed: feed) }

    // MARK: Remembered links

    func forgetChoices() {
        store.forgetAllChoices()
        refreshCounts()
    }

    func forgetChoice(_ key: String) {
        store.forgetChoice(key: key)
        refreshCounts()
    }

    func refreshCounts() {
        rememberedCount = store.choiceCount()
        postCount = store.count(source: .feed)
        objectWillChange.send()
    }
}

/// Runs `body`, cancelling it after `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SourceError("Sign-in timed out; try again")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Opens a link in the default browser. With `activate: false` the browser loads it behind the current app.
func openLink(_ url: URL, activate: Bool = true) {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = activate
    NSWorkspace.shared.open(url, configuration: config)
}
