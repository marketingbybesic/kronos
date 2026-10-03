// The deterministic part of the dread flag (adhd-engine §1.2). Two signals can be decided by
// code alone, without a model:
//
//   S1  a task carried for two or more days (`carryCount >= 2`);
//   S2  avoidance language in the title or notes ("finally", "konačno", "keep putting off", ...).
//
// The conflict, money and owed-apology signals (S3-S5) need judgement, so they stay with
// triage (the `dread` key of the triage result). A flag that fires on everything marks
// nothing, which is why the word list is kept to avoidance phrases only.
//
// Rules only ever SET the flag. They never clear it, and the night sweep sets it only on the day
// the carry count reaches the threshold, so a person who switches it off is not argued with.

import Foundation

public enum DreadRules {

    /// The carry count at which a task is treated as avoided.
    public static let carryThreshold = 2

    /// Avoidance phrases, already folded (lower case, no diacritics). Matched as whole words or
    /// word sequences, never as a part of a longer word.
    static let avoidancePhrases: [String] = [
        // English
        "finally", "should have", "still haven't", "still havent", "keep putting off",
        "keeps putting off", "been meaning to", "overdue", "at last",
        // Croatian (folded: konačno -> konacno, trebao sam, još nisam -> jos nisam)
        "konacno", "napokon", "trebao sam", "trebala sam", "jos nisam", "odgadam", "stalno odgadam",
    ]

    /// True when the title or notes contain an avoidance phrase.
    public static func matchesAvoidanceWords(title: String, notes: String = "") -> Bool {
        let text = tokens(KTextFold.fold(title + " " + notes))
        guard !text.isEmpty else { return false }
        for phrase in avoidancePhrases {
            let words = tokens(phrase)
            guard !words.isEmpty, words.count <= text.count else { continue }
            for start in 0...(text.count - words.count) where Array(text[start..<(start + words.count)]) == words {
                return true
            }
        }
        return false
    }

    /// S1: the carry count has reached the threshold.
    public static func carryReachesThreshold(_ carryCount: Int) -> Bool { carryCount >= carryThreshold }

    /// True when a carry count moving from `before` to `after` crosses the threshold on this
    /// step. The sweep flags a task exactly then, not on every later day.
    public static func carryCrossesThreshold(from before: Int, to after: Int) -> Bool {
        before < carryThreshold && after >= carryThreshold
    }

    /// Whether a task created with these words should start out flagged.
    public static func shouldFlagOnCreate(title: String, notes: String) -> Bool {
        matchesAvoidanceWords(title: title, notes: notes)
    }

    /// Words split on anything that is not a letter, digit or apostrophe.
    private static func tokens(_ folded: String) -> [String] {
        folded.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}") })
            .map { String($0).replacingOccurrences(of: "\u{2019}", with: "'") }
    }
}
