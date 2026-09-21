// Kronos/TimeBlocks/TimeBlockSelection.swift
// Foundation-only pure functions, hand-tested by scripts/timeblocks-selftest.swift against
// this exact file compiled standalone (no KronosCore, no AppModel — same shape as
// Kronos/Permissions/PermissionRowLogic.swift). A block is any `(start, end)` pair; the caller
// (TimeBlocksModel) supplies real `KCalendarEvent` times, the self-test supplies a hand-tabled
// fixture — neither needs the other's type.
import Foundation

enum TimeBlockSelection {
    /// The block containing `now`, else the most recently STARTED block even if it has already
    /// ended (so an ended block stays on screen with its switch/stay prompt instead of silently
    /// skipping to the next one — the app should ask before auto-advancing), else the
    /// first upcoming block when nothing has started yet, else nil for an empty day. Blocks are
    /// assumed sorted by `start` ascending, matching `CoachModel.todaysBlocks`'s own contract.
    static func currentIndex(blocks: [(start: Date, end: Date)], now: Date) -> Int? {
        guard !blocks.isEmpty else { return nil }
        if let started = blocks.lastIndex(where: { $0.start <= now }) { return started }
        return 0
    }

    /// True once `now` has reached or passed `index`'s block end — the moment the in-view
    /// "switch or stay" prompt should appear. False for an out-of-range index (nothing to end).
    static func hasBlockEnded(blocks: [(start: Date, end: Date)], index: Int, now: Date) -> Bool {
        guard blocks.indices.contains(index) else { return false }
        return now >= blocks[index].end
    }

    /// Clamped step, never wrapping — Left at the first block or Right at the last is a no-op,
    /// matching the arrow buttons being disabled at the ends rather than cycling.
    static func stepped(index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }

    /// `TimeBlocksModel.reload`'s whole resolution rule, pulled out pure so it can be
    /// hand-tested against a real reported bug: a screen already on a block keeps it if it
    /// still exists; otherwise a manual pick (arrows, strip,
    /// "Stay") wins if its event still exists TODAY, ended or not — a manual pick never loses to
    /// auto-advance just because its block ended, only to another manual pick or a day change
    /// (both expressed by the caller passing `manualEventID: nil` once true); otherwise fall
    /// back to `currentIndex`'s own clock-based pick.
    static func resolvedIndex(blocks: [(start: Date, end: Date)], eventIDs: [String],
                              keepEventID: String?, manualEventID: String?, now: Date) -> Int? {
        if let keepEventID, let i = eventIDs.firstIndex(of: keepEventID) { return i }
        if let manualEventID, let i = eventIDs.firstIndex(of: manualEventID) { return i }
        return currentIndex(blocks: blocks, now: now)
    }
}
