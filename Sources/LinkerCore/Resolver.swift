import Foundation

/// Turns selected text into either a link that is safe to insert or a ranked list to choose from.
///
/// Certain only when: the user picked a link for this exact text before, or exactly one curated
/// entity (a link list or a blog) has this name or alias. Everything else goes to the picker.
public final class Resolver: @unchecked Sendable {
    public let store: Store

    public init(store: Store) {
        self.store = store
    }

    public func resolve(_ text: String, limit: Int = 8) -> Resolution {
        let key = Normalize.key(text)
        guard !key.isEmpty else { return .choose([]) }
        if let c = certain(key: key) { return .certain(c) }
        return .choose(candidates(for: text, limit: limit))
    }

    /// The link for a normalized key when no question needs asking: a remembered choice, or one curated match.
    public func certain(key: String) -> Candidate? {
        if let remembered = store.choice(key: key) { return remembered }
        let exact = exactMatches(key: key)
        return exact.count == 1 && exact[0].source.isCurated ? exact[0] : nil
    }

    /// Ranked options for the picker's search field.
    public func candidates(for query: String, limit: Int = 8) -> [Candidate] {
        let key = Normalize.key(query)
        var exact: [Candidate] = []
        if let remembered = store.choice(key: key) { exact.append(remembered) }
        exact += exactMatches(key: key)
        return Array(Self.unique(exact + store.search(query, limit: limit).map(Candidate.init)).prefix(limit))
    }

    private func exactMatches(key: String) -> [Candidate] {
        Self.unique(store.exact(key: key).sorted { $0.source.priority < $1.source.priority }.map(Candidate.init))
    }

    /// Keeps the first candidate per URL, ignoring "www." and a trailing slash.
    public static func unique(_ list: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return list.filter { seen.insert(urlKey($0.url)).inserted }
    }

    public static func urlKey(_ u: URL) -> String {
        u.displayString.lowercased()
    }
}

/// Finds every known name in a whole text, for "Link all".
public struct LinkScanner {
    public struct Match: Identifiable, Hashable, Sendable {
        public var id: Int { range.location }
        /// UTF-16 range in the scanned text.
        public let range: NSRange
        public let text: String
        public let candidate: Candidate
    }

    let resolver: Resolver
    let maxWords: Int

    public init(resolver: Resolver, maxWords: Int = 6) {
        self.resolver = resolver
        self.maxWords = maxWords
    }

    /// The first mention of each known name, longest name first, skipping `excluded` ranges (text that already has a link).
    /// A name written with a capital (as in "Notion") only matches capitalized text, so "the notion that…" is left alone.
    public func scan(_ text: String, excluding excluded: [NSRange] = []) -> [Match] {
        let ns = text as NSString
        var words: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, r, _, _ in words.append(r) }

        var out: [Match] = []
        var seenURLs = Set<String>()
        var i = 0
        outer: while i < words.count {
            for length in stride(from: min(maxWords, words.count - i), through: 1, by: -1) {
                let span = NSUnionRange(words[i], words[i + length - 1])
                if excluded.contains(where: { NSIntersectionRange($0, span).length > 0 }) { continue }
                let s = ns.substring(with: span)
                // Never span a line break: names don't continue across paragraphs.
                if s.contains(where: \.isNewline) { continue }
                let key = Normalize.key(s)
                guard !key.isEmpty, let c = resolver.certain(key: key), Self.caseFits(s, c.title) else { continue }
                if seenURLs.insert(Resolver.urlKey(c.url)).inserted {
                    out.append(Match(range: span, text: s, candidate: c))
                }
                i += length
                continue outer
            }
            i += 1
        }
        return out
    }

    static func caseFits(_ text: String, _ name: String) -> Bool {
        guard let n = name.first, n.isUppercase else { return true }
        return text.first?.isUppercase == true || text.first?.isNumber == true
    }
}
