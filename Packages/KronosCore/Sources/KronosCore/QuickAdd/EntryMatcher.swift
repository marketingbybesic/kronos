import Foundation

/// How well a typed key matches a name, best first. The order is the ranking contract:
/// exact > prefix > word-prefix > contains > fuzzy.
public enum EntryMatchTier: Int, Comparable, Sendable {
    case exact, prefix, wordPrefix, contains, fuzzy

    public static func < (a: EntryMatchTier, b: EntryMatchTier) -> Bool { a.rawValue < b.rawValue }
}

/// One whitespace-separated word of a line, with its UTF-16 range.
struct EntryWord: Equatable {
    var text: String
    var range: Range<Int>
}

enum EntryMatcher {

    /// Case, diacritics and separators out of the way: "Acme-Škola" and "acme skola" are the
    /// same key. `đ` folds to `d` (KTextFold). Dashes and underscores read as spaces so
    /// `#hit-list` addresses "Hit list".
    static func normalize(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return KTextFold.fold(spaced).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Tier of `key` inside `candidate`, both already `normalize`d; nil when it does not match
    /// at all. Word-prefix means the key starts at a word boundary inside the name ("list" in
    /// "hit list"); contains is any other substring; fuzzy is the key's letters appearing in
    /// order ("hl" in "hit list"), only for keys of two letters or more.
    static func tier(key: String, candidate: String) -> EntryMatchTier? {
        guard !key.isEmpty, !candidate.isEmpty else { return nil }
        if candidate == key { return .exact }
        if candidate.hasPrefix(key) { return .prefix }
        if candidate.contains(" " + key) { return .wordPrefix }
        if candidate.contains(key) { return .contains }
        let letters = key.filter { $0 != " " }
        guard letters.count >= 2 else { return nil }
        var rest = letters[...]
        for c in candidate where c == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return .fuzzy }
        }
        return nil
    }

    struct Hit {
        var name: EntryName
        var kind: EntryDestination.Kind
        var tier: EntryMatchTier
        /// Position in the directory (projects first, then areas): the last tie-break.
        var order: Int
    }

    /// Ranked matches of `key` over `names`: tier first, then most recently used, then
    /// project before area, then directory order. `maxTier` cuts off the loose tiers (the
    /// parser resolves only up to contains; suggestions also show fuzzy).
    static func rank(key: String, projects: [EntryName], areas: [EntryName],
                     maxTier: EntryMatchTier) -> [Hit] {
        var hits: [Hit] = []
        var order = 0
        for (names, kind) in [(projects, EntryDestination.Kind.project), (areas, .area)] {
            for n in names where !n.name.isEmpty {
                defer { order += 1 }
                if let t = tier(key: key, candidate: normalize(n.name)), t <= maxTier {
                    hits.append(Hit(name: n, kind: kind, tier: t, order: order))
                }
            }
        }
        return hits.sorted(by: before)
    }

    static func before(_ a: Hit, _ b: Hit) -> Bool {
        if a.tier != b.tier { return a.tier < b.tier }
        switch (a.name.lastUsed, b.name.lastUsed) {
        case let (x?, y?) where x != y: return x > y
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if a.kind != b.kind { return a.kind == .project }
        return a.order < b.order
    }

    /// Splits a line on whitespace, keeping each word's UTF-16 range.
    static func words(in s: String) -> [EntryWord] {
        var out: [EntryWord] = []
        var start: String.Index?
        var startOffset = 0
        var offset = 0
        for idx in s.indices {
            let c = s[idx]
            if c.isWhitespace {
                if let st = start { out.append(EntryWord(text: String(s[st..<idx]), range: startOffset..<offset)); start = nil }
            } else if start == nil {
                start = idx
                startOffset = offset
            }
            offset += c.utf16.count
        }
        if let st = start { out.append(EntryWord(text: String(s[st...]), range: startOffset..<offset)) }
        return out
    }

    /// True for a word that begins a token of its own, so it can never be the continuation of a
    /// multi-word name: `#x`, `@x`, `!!`, `*m`, `~l`.
    static func startsToken(_ w: String) -> Bool {
        guard let f = w.first else { return false }
        return f == "#" || f == "@" || f == "!" || f == "*" || f == "~"
    }
}
