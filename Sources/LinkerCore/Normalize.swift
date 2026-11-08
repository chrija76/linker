import Foundation

public enum Normalize {
    private static let legalSuffixes: Set<String> = ["gmbh", "inc", "ltd", "llc", "ag", "se", "sa", "sas", "bv", "plc", "co", "corp", "limited"]

    /// Matching key: case/diacritic-folded, punctuation as spaces, no leading "the", no possessive, no legal suffix.
    /// "The Acme's" → "acme", "Globex Systems GmbH" → "globex systems", "Initech.io" → "initech io".
    public static func key(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        t = trimmed.hasSuffix("'s") ? String(trimmed.dropLast(2)) : trimmed
        let chars = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        var words = String(chars).split(separator: " ").map(String.init)
        if words.count > 1, words.first == "the" { words.removeFirst() }
        if words.count > 1, let last = words.last, legalSuffixes.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }
}
