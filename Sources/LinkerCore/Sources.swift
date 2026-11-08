import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A feed of entities that is re-synced as a whole.
public protocol EntitySource: Sendable {
    /// Stable id; everything stored under it is replaced on each sync.
    var feed: String { get }
    func fetch() async throws -> [Entity]
}

public struct SourceError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Linker/1.1 (macOS)"]
        return URLSession(configuration: c)
    }()

    static func data(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw SourceError("\(req.url?.host ?? "request") returned HTTP \(code)")
        }
        return data
    }

    static func json(_ req: URLRequest) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await data(req))
    }
}

// MARK: Link lists

/// A list of links the user maintains: a local JSON/CSV file, or a JSON/CSV URL (optionally with a bearer token).
///
/// JSON: `[{"name", "url", "aliases"?, "subtitle"?, "kind"?}]` (or `{"links": [...]}`).
/// CSV: a header row with `name,url` and optionally `aliases` (separated by `;`), `subtitle`, `kind`.
/// `kind` is one of company, person, post, link; rows without one use the list's default.
public struct LinkListSource: EntitySource {
    public let id: String
    public let name: String
    public let location: String
    public let token: String?
    public let defaultKind: EntityKind
    public var feed: String { "list:\(id)" }

    public init(id: String, name: String, location: String, token: String? = nil, defaultKind: EntityKind = .company) {
        self.id = id
        self.name = name
        self.location = location
        self.token = token
        self.defaultKind = defaultKind
    }

    /// A file path (absolute, `~/…` or `file://…`); nil for remote lists.
    public var fileURL: URL? {
        let t = location.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("file://") { return URL(string: t) }
        if t.hasPrefix("/") { return URL(fileURLWithPath: t) }
        if t.hasPrefix("~/") { return URL(fileURLWithPath: NSString(string: t).expandingTildeInPath) }
        return nil
    }

    public func fetch() async throws -> [Entity] {
        let data: Data
        if let file = fileURL {
            guard FileManager.default.fileExists(atPath: file.path) else { throw SourceError("\(name): file not found") }
            data = try Data(contentsOf: file)
        } else if let url = URL.lenient(location) {
            var req = URLRequest(url: url)
            if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            data = try await HTTP.data(req)
        } else {
            throw SourceError("\(name): not a file path or URL")
        }
        let rows = try LinkListParser.parse(data)
        return rows.compactMap { r in
            guard let u = URL.lenient(r.url), !r.name.isEmpty else { return nil }
            return Entity(id: "\(feed):\(r.id ?? u.absoluteString)", kind: r.kind ?? defaultKind, source: .list,
                          name: r.name, aliases: r.aliases, url: u, subtitle: r.subtitle, badge: name)
        }
    }
}

public enum LinkListParser {
    public struct Row: Equatable, Sendable {
        public var id: String?
        public var name: String
        public var url: String
        public var aliases: [String] = []
        public var subtitle: String?
        public var kind: EntityKind?
    }

    public static func parse(_ data: Data) throws -> [Row] {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FEFF}"]))
        if text.hasPrefix("[") || text.hasPrefix("{") { return try parseJSON(data) }
        return parseCSV(text)
    }

    static func parseJSON(_ data: Data) throws -> [Row] {
        let any = try JSONSerialization.jsonObject(with: data)
        let items = (any as? [[String: Any]]) ?? ((any as? [String: Any])?["links"] as? [[String: Any]])
        guard let items else { throw SourceError("Expected a JSON array of links") }
        return items.compactMap { o in
            func str(_ k: String) -> String? { (o[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let name = str("name") ?? str("title"), let url = str("url") ?? str("website") ?? str("href") else { return nil }
            let aliases = (o["aliases"] as? [String]) ?? splitAliases(str("aliases") ?? "")
            return Row(id: str("id"), name: name, url: url, aliases: aliases.filter { !$0.isEmpty },
                       subtitle: str("subtitle") ?? str("description"), kind: str("kind").flatMap { EntityKind(rawValue: $0.lowercased()) })
        }
    }

    static func parseCSV(_ text: String) -> [Row] {
        var records = csvRecords(text)
        guard !records.isEmpty else { return [] }
        let header = records.removeFirst().map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let n = col("name", "title"), let u = col("url", "website", "link") else { return [] }
        let a = col("aliases", "alias"), s = col("subtitle", "description"), k = col("kind", "type"), i = col("id")
        return records.compactMap { r in
            func v(_ idx: Int?) -> String? {
                guard let idx, idx < r.count else { return nil }
                let t = r[idx].trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            guard let name = v(n), let url = v(u) else { return nil }
            return Row(id: v(i), name: name, url: url, aliases: splitAliases(v(a) ?? ""), subtitle: v(s),
                       kind: v(k).flatMap { EntityKind(rawValue: $0.lowercased()) })
        }
    }

    static func splitAliases(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == ";" || $0 == "|" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// RFC 4180-ish: quoted fields, doubled quotes, commas and newlines inside quotes; also accepts `;` or tab separators.
    static func csvRecords(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let sep: Character = firstLine.contains(",") ? "," : firstLine.contains("\t") ? "\t" : firstLine.contains(";") ? ";" : ","
        var records: [[String]] = []
        var field = "", record: [String] = []
        var quoted = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == sep {
                record.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                record.append(field); field = ""
                if record.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { records.append(record) }
                record = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return records
    }
}

// MARK: Blogs and newsletters

/// A blog's posts: the full archive for Substack publications (custom domains too), otherwise its RSS or Atom feed.
public struct FeedSource: EntitySource {
    public let address: URL
    public var feed: String { "feed:\(address.host ?? address.absoluteString)\(address.path)" }

    public init?(_ address: String) {
        guard let u = URL.lenient(address) else { return nil }
        self.address = u
    }

    var badge: String {
        var h = address.displayHost
        if h.hasSuffix(".substack.com") { h.removeLast(".substack.com".count) }
        return h
    }

    public func fetch() async throws -> [Entity] {
        let host = URL(string: "https://\(address.host!)")!
        let hasPath = !address.path.isEmpty && address.path != "/"
        if !hasPath, let posts = try? await substackArchive(host), !posts.isEmpty { return posts }
        // A feed address as given, then the usual places.
        let candidates = (hasPath ? [address] : []) + ["feed", "rss", "feed.xml", "atom.xml", "index.xml", "rss.xml"]
            .map { host.appendingPathComponent($0) }
        var lastError: Error = SourceError("\(address.displayHost): no Substack archive or RSS/Atom feed found")
        for url in candidates {
            do {
                let items = FeedParser.parse(try await HTTP.data(URLRequest(url: url)))
                if !items.isEmpty {
                    return items.map { Entity(id: "feed:\($0.url.absoluteString)", kind: .post, source: .feed, name: $0.title,
                                              url: $0.url, subtitle: $0.summary, date: $0.date, badge: badge) }
                }
            } catch { lastError = error }
        }
        throw lastError
    }

    private func substackArchive(_ base: URL) async throws -> [Entity] {
        // Newer publications page with a cursor (`{"posts": [...], "nextCursor": "..."}`), older ones with an offset
        // (a bare array). The first request works for both: no offset, a page size both accept.
        var out: [Entity] = []
        var offset = 0
        var cursor: String?
        let pageSize = 20
        for _ in 0..<250 {
            var comps = URLComponents(url: base.appendingPathComponent("api/v1/archive"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [.init(name: "sort", value: "new"), .init(name: "limit", value: "\(pageSize)")]
            if let cursor { comps.queryItems!.append(.init(name: "cursor", value: cursor)) }
            else if offset > 0 { comps.queryItems!.append(.init(name: "offset", value: "\(offset)")) }
            let reply = try await HTTP.json(URLRequest(url: comps.url!))
            let page: [[String: Any]]
            if let list = reply as? [[String: Any]] {
                page = list
            } else if let o = reply as? [String: Any], let posts = o["posts"] as? [[String: Any]] {
                page = posts
                cursor = o["nextCursor"] as? String
            } else { break }
            if page.isEmpty { break }
            for p in page {
                guard let title = (p["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                      let u = (p["canonical_url"] as? String).flatMap(URL.init(string:)) else { continue }
                out.append(Entity(id: "feed:\(u.absoluteString)", kind: .post, source: .feed, name: title, url: u,
                                  subtitle: p["subtitle"] as? String, date: (p["post_date"] as? String).flatMap(Self.parseDate),
                                  badge: badge))
            }
            if reply is [String: Any] {
                if cursor == nil { break }
            } else {
                offset += page.count
            }
        }
        return out
    }

    public static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Minimal RSS 2.0 / Atom reader: title, link, date and summary per item.
public final class FeedParser: NSObject, XMLParserDelegate {
    public struct Item: Sendable {
        public let title: String
        public let url: URL
        public let date: Date?
        public let summary: String?
    }

    private var items: [Item] = []
    private var inItem = false
    private var text = ""
    private var title = "", link = "", date = "", summary = ""

    public static func parse(_ data: Data) -> [Item] {
        let p = FeedParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.items
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                       attributes: [String: String] = [:]) {
        let n = name.lowercased()
        if n == "item" || n == "entry" {
            inItem = true
            title = ""; link = ""; date = ""; summary = ""
        } else if inItem, n == "link", let href = attributes["href"], attributes["rel"] ?? "alternate" == "alternate" {
            link = href // Atom
        }
        text = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inItem else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "title": title = t
        case "link": if link.isEmpty { link = t }
        case "pubdate", "published", "updated", "dc:date": if date.isEmpty { date = t }
        case "description", "summary", "content:encoded":
            if summary.isEmpty { summary = Self.stripTags(t) }
        case "item", "entry":
            inItem = false
            if !title.isEmpty, let u = URL.lenient(link) {
                items.append(Item(title: title, url: u, date: Self.date(date),
                                  summary: summary.isEmpty ? nil : String(summary.prefix(160))))
            }
        default: break
        }
        text = ""
    }

    static func date(_ s: String) -> Date? {
        if let d = FeedSource.parseDate(s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: Sync

public struct SyncReport: Sendable {
    public let feed: String
    public let count: Int
    public let error: String?
}

public enum Sync {
    /// Fetches every source concurrently; a failing source keeps its previous data.
    public static func run(_ sources: [any EntitySource], into store: Store) async -> [SyncReport] {
        await withTaskGroup(of: SyncReport.self) { group in
            for s in sources {
                group.addTask {
                    do {
                        let entities = try await s.fetch()
                        try store.replace(feed: s.feed, with: entities)
                        return SyncReport(feed: s.feed, count: entities.count, error: nil)
                    } catch {
                        return SyncReport(feed: s.feed, count: 0, error: "\(error)")
                    }
                }
            }
            var out: [SyncReport] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.feed < $1.feed }
        }
    }
}

// MARK: Link check

public enum LinkCheck {
    /// True when the URL answers at all (2xx/3xx, or 401/403/405 from sites that block HEAD). Gate for auto-insert.
    public static func isAlive(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await HTTP.session.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode else {
            return false
        }
        return (200..<400).contains(code) || [401, 403, 405, 429].contains(code)
    }
}
