import Foundation
import CSQLite

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String { if case .sqlite(let m) = self { return m }; return "store error" }
}

/// Local index of linkable entities plus the user's remembered choices. Thread-safe.
public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.sqlite("cannot open \(path)")
        }
        // Synced data is disposable: on a schema change, drop it (the next sync refills it) but keep remembered choices.
        try exec("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);")
        if meta("schema") != Self.schema {
            try exec("DROP TABLE IF EXISTS entities; DROP TABLE IF EXISTS names; DROP TABLE IF EXISTS fts; DELETE FROM meta WHERE k = 'lastSync';")
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS entities(
            id TEXT PRIMARY KEY, feed TEXT NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL,
            name TEXT NOT NULL, aliases TEXT NOT NULL, url TEXT NOT NULL, subtitle TEXT, date REAL, badge TEXT);
        CREATE INDEX IF NOT EXISTS entities_feed ON entities(feed);
        CREATE TABLE IF NOT EXISTS names(key TEXT NOT NULL, entity_id TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS names_key ON names(key);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(entity_id UNINDEXED, names, body, tokenize='unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS choices(
            key TEXT PRIMARY KEY, title TEXT NOT NULL, url TEXT NOT NULL, subtitle TEXT,
            kind TEXT NOT NULL, uses INTEGER NOT NULL, last REAL NOT NULL);
        """)
        setMeta("schema", Self.schema)
    }

    private static let schema = "2"

    deinit { sqlite3_close(db) }

    // MARK: Entities

    /// Replaces everything previously synced from `feed` (e.g. "feed:blog.example.com") in one transaction.
    public func replace(feed: String, with entities: [Entity]) throws {
        try locked {
            try execUnlocked("BEGIN")
            do {
                try run("DELETE FROM names WHERE entity_id IN (SELECT id FROM entities WHERE feed = ?)", [feed])
                try run("DELETE FROM fts WHERE entity_id IN (SELECT id FROM entities WHERE feed = ?)", [feed])
                try run("DELETE FROM entities WHERE feed = ?", [feed])
                var seen = Set<String>()
                for e in entities where seen.insert(e.id).inserted {
                    let aliases = String(data: try JSONEncoder().encode(e.aliases), encoding: .utf8) ?? "[]"
                    try run("INSERT OR REPLACE INTO entities VALUES (?,?,?,?,?,?,?,?,?,?)",
                            [e.id, feed, e.kind.rawValue, e.source.rawValue, e.name, aliases, e.url.absoluteString,
                             e.subtitle, e.date?.timeIntervalSince1970, e.badge])
                    for key in Set(([e.name] + e.aliases).map(Normalize.key)) where !key.isEmpty {
                        try run("INSERT INTO names VALUES (?,?)", [key, e.id])
                    }
                    try run("INSERT INTO fts VALUES (?,?,?)", [e.id, ([e.name] + e.aliases).joined(separator: " "), e.subtitle ?? ""])
                }
                try execUnlocked("COMMIT")
            } catch {
                try? execUnlocked("ROLLBACK")
                throw error
            }
        }
    }

    /// Entities whose name or alias normalizes to exactly `key`.
    public func exact(key: String) -> [Entity] {
        (try? locked {
            try select("SELECT e.* FROM names n JOIN entities e ON e.id = n.entity_id WHERE n.key = ?", [key], entity)
        }) ?? []
    }

    public func hasExact(key: String) -> Bool {
        (try? locked { try select("SELECT 1 FROM names WHERE key = ? LIMIT 1", [key]) { _ in true } })?.isEmpty == false
    }

    /// Prefix full-text search over names (weighted) and subtitles. All words must match; falls back to any word.
    public func search(_ query: String, limit: Int = 8) -> [Entity] {
        let words = Normalize.key(query).split(separator: " ").map { "\"\($0)\"*" }
        guard !words.isEmpty else { return [] }
        let sql = "SELECT e.* FROM fts JOIN entities e ON e.id = fts.entity_id WHERE fts MATCH ? ORDER BY bm25(fts, 0, 10.0, 1.0) LIMIT ?"
        let all = (try? locked { try select(sql, [words.joined(separator: " "), limit], entity) }) ?? []
        if !all.isEmpty || words.count == 1 { return all }
        return (try? locked { try select(sql, [words.joined(separator: " OR "), limit], entity) }) ?? []
    }

    public func count(source: SourceKind) -> Int {
        (try? locked { try select("SELECT COUNT(*) FROM entities WHERE source = ?", [source.rawValue]) { $0.int(0) } })?.first ?? 0
    }

    public func count(feed: String) -> Int {
        (try? locked { try select("SELECT COUNT(*) FROM entities WHERE feed = ?", [feed]) { $0.int(0) } })?.first ?? 0
    }

    /// Feeds currently in the index, to drop ones whose source the user removed.
    public func feeds() -> [String] {
        (try? locked { try select("SELECT DISTINCT feed FROM entities", []) { $0.text(0) } }) ?? []
    }

    // MARK: Remembered choices

    public func remember(key: String, _ c: Candidate) {
        guard !key.isEmpty else { return }
        try? locked {
            try run("""
            INSERT INTO choices VALUES (?,?,?,?,?,1,?)
            ON CONFLICT(key) DO UPDATE SET title=excluded.title, url=excluded.url, subtitle=excluded.subtitle,
                kind=excluded.kind, uses=uses+1, last=excluded.last
            """, [key, c.title, c.url.absoluteString, c.subtitle, c.kind.rawValue, Date().timeIntervalSince1970])
        }
    }

    public func choice(key: String) -> Candidate? {
        (try? locked {
            try select("SELECT title, url, subtitle, kind FROM choices WHERE key = ?", [key]) { r -> Candidate? in
                guard let u = r.text(1).flatMap(URL.init(string:)) else { return nil }
                return Candidate(title: r.text(0) ?? "", url: u, subtitle: r.text(2),
                                 kind: EntityKind(rawValue: r.text(3) ?? "") ?? .link, source: .remembered)
            }
        })?.first ?? nil
    }

    public func choiceCount() -> Int {
        (try? locked { try select("SELECT COUNT(*) FROM choices", []) { $0.int(0) } })?.first ?? 0
    }

    public func forgetAllChoices() {
        try? locked { try run("DELETE FROM choices", []) }
    }

    public struct Choice: Identifiable, Hashable, Sendable {
        public var id: String { key }
        public let key: String
        public let candidate: Candidate
        public let uses: Int
        public let last: Date
    }

    /// Every remembered choice, most recently used first.
    public func allChoices() -> [Choice] {
        (try? locked {
            try select("SELECT key, title, url, subtitle, kind, uses, last FROM choices ORDER BY last DESC", []) { r -> Choice? in
                guard let key = r.text(0), let u = r.text(2).flatMap(URL.init(string:)) else { return nil }
                let c = Candidate(title: r.text(1) ?? "", url: u, subtitle: r.text(3),
                                  kind: EntityKind(rawValue: r.text(4) ?? "") ?? .link, source: .remembered)
                return Choice(key: key, candidate: c, uses: r.int(5), last: Date(timeIntervalSince1970: r.double(6) ?? 0))
            }
        }) ?? []
    }

    public func forgetChoice(key: String) {
        try? locked { try run("DELETE FROM choices WHERE key = ?", [key]) }
    }

    // MARK: Meta

    public func setMeta(_ k: String, _ v: String?) {
        try? locked { try run("INSERT OR REPLACE INTO meta VALUES (?,?)", [k, v]) }
    }

    public func meta(_ k: String) -> String? {
        (try? locked { try select("SELECT v FROM meta WHERE k = ?", [k]) { $0.text(0) } })?.first ?? nil
    }

    // MARK: SQLite plumbing

    struct Row {
        let stmt: OpaquePointer
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func double(_ i: Int32) -> Double? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    }

    private func entity(_ r: Row) -> Entity? {
        guard let id = r.text(0), let kind = r.text(2).flatMap(EntityKind.init(rawValue:)),
              let source = r.text(3).flatMap(SourceKind.init(rawValue:)), let name = r.text(4),
              let url = r.text(6).flatMap(URL.init(string:)) else { return nil }
        let aliases = r.text(5).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        return Entity(id: id, kind: kind, source: source, name: name, aliases: aliases, url: url,
                      subtitle: r.text(7), date: r.double(8).map(Date.init(timeIntervalSince1970:)), badge: r.text(9))
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func exec(_ sql: String) throws { try locked { try execUnlocked(sql) } }

    private func execUnlocked(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as String: sqlite3_bind_text(s, idx, v, -1, Store.transient)
            case let v as Int: sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(s, idx, v)
            default: sqlite3_bind_null(s, idx)
            }
        }
        return s
    }

    private func run(_ sql: String, _ args: [Any?]) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func select<T>(_ sql: String, _ args: [Any?], _ map: (Row) -> T?) throws -> [T] {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            if let v = map(Row(stmt: s)) { out.append(v) }
        }
        return out
    }
}
