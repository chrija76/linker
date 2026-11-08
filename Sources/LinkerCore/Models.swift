import Foundation

public enum EntityKind: String, Codable, Sendable, CaseIterable {
    case company, person, post, link

    /// SF Symbol shown when a site has no favicon.
    public var symbol: String {
        switch self {
        case .company: "building.2"
        case .person: "person.crop.circle"
        case .post: "doc.text"
        case .link: "link"
        }
    }
}

/// Where a link came from. Decides the default badge and whether a unique exact match may be inserted without asking.
public enum SourceKind: String, Codable, Sendable {
    /// A link the user picked for this exact text before.
    case remembered
    /// A link list the user added (a local file or a URL they trust).
    case list
    /// A blog or newsletter archive (Substack, RSS, Atom).
    case feed
    /// The user's own search endpoint, queried live from the picker.
    case search
    /// Web search results.
    case web

    public var label: String {
        switch self {
        case .remembered: "Used before"
        case .list: "List"
        case .feed: "Blog"
        case .search: "Search"
        case .web: "Web"
        }
    }

    /// Curated sources may auto-insert on a unique exact match; live search and web results never do.
    public var isCurated: Bool { self == .remembered || self == .list || self == .feed }

    /// Lower sorts first when several exact matches compete.
    var priority: Int {
        switch self {
        case .remembered: 0
        case .list: 1
        case .feed: 2
        case .search: 3
        case .web: 4
        }
    }
}

public struct Entity: Codable, Hashable, Sendable {
    public var id: String
    public var kind: EntityKind
    public var source: SourceKind
    public var name: String
    public var aliases: [String]
    public var url: URL
    public var subtitle: String?
    public var date: Date?
    /// Shown on the picker row instead of the source label, e.g. the list's name ("Clients") or a blog's host.
    public var badge: String?

    public init(id: String, kind: EntityKind, source: SourceKind, name: String, aliases: [String] = [],
                url: URL, subtitle: String? = nil, date: Date? = nil, badge: String? = nil) {
        self.id = id
        self.kind = kind
        self.source = source
        self.name = name
        self.aliases = aliases
        self.url = url
        self.subtitle = subtitle
        self.date = date
        self.badge = badge
    }
}

/// One option shown in the picker or inserted directly.
public struct Candidate: Identifiable, Hashable, Sendable {
    public var id: String { url.absoluteString }
    public var title: String
    public var url: URL
    public var subtitle: String?
    public var kind: EntityKind
    public var source: SourceKind
    public var date: Date?
    public var badge: String?

    public init(title: String, url: URL, subtitle: String? = nil, kind: EntityKind, source: SourceKind,
                date: Date? = nil, badge: String? = nil) {
        self.title = title
        self.url = url
        self.subtitle = subtitle
        self.kind = kind
        self.source = source
        self.date = date
        self.badge = badge
    }

    public init(_ e: Entity) {
        self.init(title: e.name, url: e.url, subtitle: e.subtitle, kind: e.kind, source: e.source, date: e.date, badge: e.badge)
    }

    public var badgeText: String { badge ?? source.label }

    /// Short host, e.g. "example.com".
    public var displayHost: String { url.displayHost }

    /// Host plus path without the scheme, for showing the full target, e.g. "example.com/blog/post".
    public var displayURL: String { url.displayString }
}

public enum Resolution: Sendable {
    /// Safe to insert without asking.
    case certain(Candidate)
    /// Ask the user; may be empty.
    case choose([Candidate])
}

extension URL {
    /// Accepts "example.com", "www.example.com/x" or a full URL; nil for anything that isn't http(s).
    public static func lenient(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        let lower = t.lowercased()
        if lower.contains("://") {
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        } else {
            t = "https://" + t
        }
        guard let u = URL(string: t), let host = u.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return u
    }

    /// Host without "www.".
    public var displayHost: String {
        var h = host ?? absoluteString
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// The URL without scheme, "www." or a trailing slash: "example.com/blog/post?x=1".
    public var displayString: String {
        var s = absoluteString
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
