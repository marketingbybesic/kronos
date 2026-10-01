// Kronos/QuickAdd/QuickAddDraft.swift: Foundation-only so scripts/quickadd-draft-selftest.swift can
// compile the REAL file. The one place a half-typed thought survives a close. The panel view is
// rebuilt on EVERY open (fresh text, focus, toggles: a stale entry from an hour ago must not greet
// the next one), but text left behind by Esc / click-away comes back if the panel is reopened
// within `window` seconds (ADHD: losing a thought to a mis-click is worse than one extra Cmd-A).
import Foundation

enum QuickAddDraft {
    static let window: TimeInterval = 60

    /// Pure rule: the text to seed an open at `now` with.
    static func seed(text: String, closedAt: Date?, now: Date) -> String {
        guard let closedAt, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              now.timeIntervalSince(closedAt) <= window else { return "" }
        return text
    }

    @MainActor static var text = ""
    @MainActor static var closedAt: Date?

    /// Always consumes the draft: one restore per close.
    @MainActor
    static func takeSeed(now: Date = Date()) -> String {
        defer { text = ""; closedAt = nil }
        return seed(text: text, closedAt: closedAt, now: now)
    }
}
