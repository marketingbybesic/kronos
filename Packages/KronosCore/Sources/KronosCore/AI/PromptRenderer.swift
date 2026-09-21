// Everything needed to turn a `PromptTemplates` constant into the exact
// string sent on the wire: language detection from the task title (never the
// UI locale), the `{{HOUSE_RULES}}` block, and the privacy-minimizing note
// truncation.

import Foundation

/// Output/target language. Detected client-side from task text, never from
/// the macOS UI language.
public enum Lang: String, Sendable {
    case hr, en

    public var name: String { self == .hr ? "Croatian" : "English" }
}

/// Detects HR vs EN from a piece of task text: diacritics are a certain
/// signal; otherwise a small HR stopword list decides.
public func detectLanguage(_ text: String) -> Lang {
    if text.rangeOfCharacter(from: CharacterSet(charactersIn: "čćšžđČĆŠŽĐ")) != nil { return .hr }
    let hrStopwords: Set<String> = ["i", "u", "na", "za", "je", "se", "da", "ne", "s", "o",
                                     "od", "do", "sa", "koji", "kao", "ali"]
    let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    return words.contains(where: hrStopwords.contains) ? .hr : .en
}

/// A `Sendable` snapshot of the `KRule` fields the renderer needs. `KRule` is
/// a SwiftData `@Model` class and therefore not `Sendable`; `AIRouter` must
/// be usable from an `async` call site, so the caller (which owns
/// `TaskStoring` / `MainActor` access to the real rules) converts once at the
/// boundary rather than this file holding model objects across `await`.
public struct HouseRule: Sendable {
    public let text: String
    public let scope: KRuleScope
    public let isActive: Bool
    public let createdAt: Date

    public init(text: String, scope: KRuleScope, isActive: Bool, createdAt: Date) {
        self.text = text
        self.scope = scope
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

/// Renders `{{HOUSE_RULES}}` for a given scope. Rules whose scope matches the prompt's scope or
/// is `.all` are selected, most-recently-used first, capped at `limit`
/// (30 for triage/ordo, 15 for the latency-sensitive impuls path).
public enum HouseRulesRenderer {
    public static func render(rules: [HouseRule], scope: KRuleScope, limit: Int = 30) -> String {
        let matching = rules
            .filter { $0.isActive && ($0.scope == scope || $0.scope == .all) }
            .sorted { a, b in
                // Global rules first, scope-specific last (so "later overrides
                // earlier" makes the specific rule win), createdAt ascending
                // within each group.
                let aSpecific = a.scope != .all
                let bSpecific = b.scope != .all
                if aSpecific != bSpecific { return !aSpecific }
                return a.createdAt < b.createdAt
            }
        guard !matching.isEmpty else { return "House rules: none." }
        let capped = Array(matching.prefix(limit))
        let lines = capped.enumerated().map { i, r in "\(i + 1). \(r.text)" }
        return "House rules (the user's corrections; they override your defaults):\n"
            + lines.joined(separator: "\n")
    }
}

/// Privacy minimization. Truncates notes to
/// 300 characters and redacts obvious secrets before any text leaves the
/// process: emails, phone numbers, IBAN/OIB-like digit runs, and URLs
/// carrying a query string (tokens).
public enum PrivacyRedactor {
    /// Truncate to at most 300 characters, then redact.
    public static func sanitizeNotes(_ notes: String) -> String {
        redact(String(notes.prefix(300)))
    }

    /// Capture's privacy pass. Pasted notes can be a full brain dump — the
    /// 300-character cut that `sanitizeNotes` applies
    /// would destroy most of it, so this caps at 6000 characters instead and
    /// adds two redactions `redact(_:)` does not cover: IBAN/OIB-style runs
    /// broken up with spaces or dashes wider than the 8-digit heuristic
    /// already catches (unchanged here — it already matches), and explicit
    /// `password:` / `lozinka:` value lines, which are prose, not a number or
    /// an email, and so need their own pattern.
    public static func sanitizeCapture(_ text: String) -> String {
        var out = redact(String(text.prefix(6000)))
        out = replace(out, pattern: #"(?i)(password|lozinka)\s*:\s*\S+"#, with: "$1: [redacted]")
        return out
    }

    /// Redaction only, no truncation — used where the caller already applied
    /// its own length limit (e.g. a title, which is short by construction).
    public static func redact(_ text: String) -> String {
        var out = text
        out = replace(out, pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "[redacted-email]")
        out = replace(out, pattern: #"https?://\S+\?\S+"#, with: "[redacted-url]")
        // IBAN-like / OIB-like: a run of 8+ digits, optionally interleaved with
        // spaces/dashes, at least 8 raw digits total. Matched before the plain
        // phone pattern so a long digit run is not left half-redacted.
        out = replace(out, pattern: #"(?:\d[ -]?){8,}\d"#, with: "[redacted-number]")
        // Phone numbers: +countrycode or a run of 6+ digits with separators,
        // already mostly covered above; this catches shorter local numbers.
        out = replace(out, pattern: #"\+\d[\d ()-]{5,}\d"#, with: "[redacted-number]")
        return out
    }

    private static func replace(_ text: String, pattern: String, with token: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: token)
    }
}

/// Fills `{{...}}` placeholders in a template. A tiny helper rather than a
/// templating dependency — every placeholder is a literal, non-overlapping
/// token, and there are at most a dozen per prompt.
enum TemplateFill {
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return out
    }
}
