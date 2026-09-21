// Kronos/TimeBlocks/TimeBlocksModel.swift
//
// A view scoped to one calendar block's tasks at a time, togglable in Settings, showing only
// the tasks assigned to the current time block so Ordo reflects it immediately; manual ‹ ›
// navigation lets you step between the day's blocks by hand, and an end-of-block "switch or
// stay" prompt asks whether to move to the next block or remain on the current one.
//
// Pure selection logic lives in Kronos/TimeBlocks/TimeBlockSelection.swift (Foundation only, no
// KronosCore, no AppModel) so scripts/timeblocks-selftest.swift can hand-table it against that
// real file directly, with zero build dependencies beyond Foundation — same shape as
// scripts/permissions-selftest.swift compiling PermissionRowLogic.swift standalone.
// `TimeBlocksModel` is the thin @Observable wrapper the screen drives — it reads
// `model.coach.todaysBlocks` (already resolved to a project per block: keyword + learned-link
// matching happens once in CoachModel, this leaf never re-implements it) and holds only the
// UI-local state CoachModel doesn't (which index is on screen, the end-of-block prompt's
// dismissal).
import Foundation
import Observation
import KronosCore

/// One calendar block plus the project it resolves to (nil = unmatched: no linked project).
/// Mirrors `CoachModel.todaysBlocks`'s own tuple shape so the screen and the pure logic below
/// share one vocabulary without either side importing the other's type.
struct TimeBlockEntry: Equatable, Identifiable {
    let event: KCalendarEvent
    let projectID: UUID?
    var id: String { event.id }
}

/// The screen's own state: which block is on screen, and the end-of-block prompt's answer for
/// THIS block (so it does not re-appear the moment it is dismissed, until moving on).
@MainActor
@Observable
final class TimeBlocksModel {
    private unowned let model: AppModel

    private(set) var blocks: [TimeBlockEntry] = []
    var currentIndex: Int?
    /// Set once "stay" is answered for the block currently ended, so the prompt does not
    /// re-appear every re-render while lingering on it; cleared on any navigation.
    private var staidThroughEventID: String?
    /// The `now` last passed to `reload(now:)` — `showsEndedPrompt` reads this rather than a
    /// fresh `Date()` so a frozen `previewNow` (gate shots) and a live reload (real launch,
    /// re-run every minute per CoachModel's own cadence) behave identically: "ended" always
    /// means "as of the moment we last looked," never a clock read mid-render.
    private var lastKnownNow: Date = Date()

    /// Snapshot-only seam: when set, `reload(now:)` reads these blocks instead of
    /// `model.coach.todaysBlocks` — the harness's CoachModel has no real calendar to seed
    /// `todaysBlocks` from, the same wiring gap `CoachBanner.previewSuggestion` also has.
    private var previewBlocks: [TimeBlockEntry]?

    init(model: AppModel) {
        self.model = model
        reload(now: Date())
    }

    /// Called only by `TimeBlocksScreen`'s preview path (`TimeBlocksSnapshots`). Overwrites the
    /// block source and re-derives `currentIndex` against a frozen `now` so a gate shot is
    /// deterministic instead of racing the real clock.
    func setPreview(blocks: [TimeBlockEntry], now: Date) {
        previewBlocks = blocks
        reload(now: now)
    }

    // MARK: Derived

    var current: TimeBlockEntry? { currentIndex.flatMap { blocks.indices.contains($0) ? blocks[$0] : nil } }
    var next: TimeBlockEntry? { currentIndex.flatMap { i in blocks.indices.contains(i + 1) ? blocks[i + 1] : nil } }
    var canGoPrevious: Bool { (currentIndex ?? 0) > 0 }
    var canGoNext: Bool { let i = currentIndex ?? -1; return i + 1 < blocks.count }

    /// True when the current block's end time has passed and "stay" has not already been
    /// answered for this exact event.
    var showsEndedPrompt: Bool {
        guard let current, let currentIndex else { return false }
        guard TimeBlockSelection.hasBlockEnded(blocks: blocks.map { ($0.event.start, $0.event.end) }, index: currentIndex, now: lastKnownNow) else { return false }
        return staidThroughEventID != current.event.id
    }

    /// Tasks belonging to the on-screen block: linked directly to its event (`TaskCalendarLink`)
    /// or belonging to the project CoachModel already matched the block to. A task counts once
    /// even if both are true.
    var focusTaskIDs: [UUID] {
        guard let current else { return [] }
        return tasks(for: current).map(\.id)
    }

    func tasks(for entry: TimeBlockEntry) -> [KTask] {
        let all = model.store.allTasks().filter { $0.status != .done && $0.deletedAt == nil }
        var result: [KTask] = []
        for task in all {
            let linkedToEvent = TaskCalendarLink.find(in: task.notes)?.eventID == entry.event.id
            let inLinkedProject = entry.projectID != nil && task.project?.id == entry.projectID
            guard linkedToEvent || inLinkedProject else { continue }
            result.append(task)
        }
        return KTaskSorter.sorted(result, by: KSortDescriptor.default)
    }

    /// The menu bar's one question ("does block precedence apply, and to which task?"),
    /// answered here once so `MenuBarOrdoController`/`PopoverContent` (Kronos/MenuBar/**)
    /// never re-derive it — `MenuBarBlockFocus` (Foundation-only, hand-tested) is the actual
    /// rule; this just supplies its real inputs from the same `current`/`focusTaskIDs` the
    /// screen itself renders from, so the bar and the view can never disagree about which
    /// block is current.
    var blockFocusTaskID: UUID? {
        MenuBarBlockFocus.focusTaskID(settingOn: TimeBlocksPrefs.menuBarFollows,
                                       viewEnabled: TimeBlocksPrefs.isEnabled,
                                       hasCurrentBlock: current != nil,
                                       blockTaskIDs: focusTaskIDs)
    }

    // MARK: Actions

    /// Call on `.onAppear`, on `model.version` changes and once a minute while the screen is
    /// open (same cadence CoachModel documents for `refreshBlocks`) — re-reads the resolved
    /// blocks and keeps the on-screen index pointed at the same event if it still exists.
    /// `previewBlocks == nil` also honours a manual pick from `TimeBlocksPrefs.manualEventID`:
    /// switching block with the arrows should update the menu bar at once, and the bar
    /// constructs its OWN `TimeBlocksModel` per render, so manual navigation has to reach it
    /// through something more durable than this instance's own `currentIndex`.
    ///
    /// A manual pick (or "Stay") HOLDS across its block ending — it is only dropped by
    /// `TimeBlocksPrefs.manualEventID` itself reading nil (an explicit Switch/another pick
    /// already overwrote it, or the day changed), never by this function noticing the block
    /// ended. The reported case that drove this — picked/arrived-at block ends, Switch not
    /// yet answered, one linked open task — must keep driving the bar. This is what
    /// `TimeBlocksPrefs.manualEventID` itself is for: `reload` here only reads it, it never
    /// second-guesses it.
    func reload(now: Date = Date()) {
        lastKnownNow = now
        let keepEventID = current?.event.id
        blocks = previewBlocks ?? model.coach.todaysBlocks.map { TimeBlockEntry(event: $0.event, projectID: $0.projectID) }
        let manualID = previewBlocks == nil ? TimeBlocksPrefs.manualEventID : nil
        currentIndex = TimeBlockSelection.resolvedIndex(blocks: blocks.map { ($0.event.start, $0.event.end) },
                                                         eventIDs: blocks.map(\.event.id),
                                                         keepEventID: keepEventID, manualEventID: manualID, now: now)
        // The block this SCREEN arrived at by itself has ended and the prompt has not been
        // answered yet (the reported case: banner up, bar already gone to the next block).
        // Only a screen instance gets here: a fresh bar-side model has no `keepEventID`, so
        // its auto-selected block is never an ended one kept from before. Persist it so the
        // bar keeps following.
        if previewBlocks == nil, manualID == nil, keepEventID != nil, showsEndedPrompt { rememberManualPick() }
    }

    /// Persists the on-screen block as the manual pick (skipped for a preview/snapshot
    /// instance) and tells the menu bar to re-render against it immediately, rather than
    /// waiting for its own next `focusChanged`-triggering event.
    private func rememberManualPick() {
        guard previewBlocks == nil, let eventID = current?.event.id else { return }
        TimeBlocksPrefs.setManualPick(eventID: eventID)
        NotificationCenter.default.post(name: .kronosOrdoFocusDidChange, object: nil)
    }

    func goPrevious() {
        guard let currentIndex else { return }
        self.currentIndex = TimeBlockSelection.stepped(index: currentIndex, by: -1, count: blocks.count)
        staidThroughEventID = nil
        rememberManualPick()
    }

    func goNext() {
        guard let currentIndex else { return }
        self.currentIndex = TimeBlockSelection.stepped(index: currentIndex, by: 1, count: blocks.count)
        staidThroughEventID = nil
        rememberManualPick()
    }

    /// Direct jump — the day strip's own tap target, alongside the arrow-by-arrow
    /// `goPrevious`/`goNext`. Ignores an out-of-range index rather than clamping it,
    /// since the only caller (the day strip) always passes one of `blocks`' own indices.
    func jump(to index: Int) {
        guard blocks.indices.contains(index) else { return }
        currentIndex = index
        staidThroughEventID = nil
        rememberManualPick()
    }

    /// "Switch": move on-screen to the next block (mirrors CoachModel's own switch semantics,
    /// scoped to navigation within this screen rather than changing `model.scope`).
    func switchToNext() {
        guard let currentIndex, blocks.indices.contains(currentIndex + 1) else { return }
        self.currentIndex = currentIndex + 1
        staidThroughEventID = nil
        rememberManualPick()
    }

    /// "Stay": silence the ended prompt for this block without moving, and make it a real
    /// manual pick — auto-advance should only happen through the Switch answer or when there
    /// is no manual pick, otherwise a block only reached automatically, then chosen to stay
    /// on, would still lose to auto-advance on the very next `reload`.
    func stay() {
        staidThroughEventID = current?.event.id
        rememberManualPick()
    }
}
