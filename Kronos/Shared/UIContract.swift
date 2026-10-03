// UI CONTRACT — the single shared surface between the app's UI areas.
//
// The UI is organized into a handful of largely independent areas (window shell + sidebar,
// task list, inspector, menu bar + quick add) that only communicate through the state
// defined here — never directly with each other's internals.
//
//   Kronos/App/**  Kronos/Sidebar/**   -> SidebarScreen, window shell, wiring
//   Kronos/List/**                     -> TaskListScreen (+ view-options popover)
//   Kronos/Detail/**                   -> InspectorScreen
//   Kronos/MenuBar/** Kronos/QuickAdd/** -> MenuBarOrdoController, QuickAddController
//
// Every root screen takes exactly one argument: the shared `AppModel`.

import Foundation
import Observation
import KronosCore

// LAUNCHSCOPE-BEGIN (compiled standalone by scripts/launchscope-selftest.swift: keep it Foundation-only)
/// Which list a normal launch opens on: Today when it has open tasks, then Inbox, then All (F1).
/// Hermetic runs (snapshots, self-tests, UI test, custom store dir) keep `.inbox` so they stay
/// deterministic.
enum LaunchScopeChoice: Equatable { case inbox, today, all }

enum LaunchScope {
    static let hermeticEnv = ["KRONOS_SNAPSHOT", "KRONOS_STORE_DIR", "KRONOS_SELFTEST", "KRONOS_UITEST"]

    static func isHermetic(_ env: [String: String]) -> Bool { hermeticEnv.contains { env[$0] != nil } }

    static func pick(hermetic: Bool, inboxOpen: Int, todayOpen: Int) -> LaunchScopeChoice {
        if hermetic { return .inbox }
        if todayOpen > 0 { return .today }
        return inboxOpen > 0 ? .inbox : .all
    }
}
// LAUNCHSCOPE-END

/// What the list pane is showing. Persisted per window via `AppModel`.
enum ListScope: Hashable, Codable, Sendable {
    case inbox, today, next7, waiting, someday, all
    case project(UUID)
    case area(UUID)
    case savedView(UUID)

    /// Fixed scopes in sidebar order. ⌘1…⌘6 map onto these.
    static let fixed: [ListScope] = [.inbox, .today, .next7, .waiting, .someday, .all]

    /// Localisation key for fixed scopes (see Localizable.xcstrings); nil for dynamic scopes,
    /// whose title comes from the project / area / saved view itself.
    var titleKey: String? {
        switch self {
        case .inbox: return "sidebar.inbox"
        case .today: return "sidebar.today"
        case .next7: return "sidebar.next7"
        case .waiting: return "sidebar.waiting"
        case .someday: return "sidebar.someday"
        case .all: return "sidebar.all"
        case .project, .area, .savedView: return nil
        }
    }

    /// Stable key for per-scope persisted view options (sort + filter).
    var storageKey: String {
        switch self {
        case .inbox: return "inbox"
        case .today: return "today"
        case .next7: return "next7"
        case .waiting: return "waiting"
        case .someday: return "someday"
        case .all: return "all"
        case .project(let id): return "project." + id.uuidString
        case .area(let id): return "area." + id.uuidString
        case .savedView(let id): return "view." + id.uuidString
        }
    }
}

/// Requests one area posts and another fulfils, by raw notification name (the raw strings are
/// the contract; the names here are only this file's spelling of them). `userInfo["taskID"]`
/// carries the task as a UUID where one is named.
enum UIRequests {
    /// Put keyboard focus in the inspector's title field (list Return). Esc there posts
    /// `kronosFocusListRequested` and the list takes focus back.
    static let focusInspectorTitle = Notification.Name("kronosFocusInspectorTitleRequested")
    /// The list takes keyboard focus.
    static let focusList = Notification.Name("kronosFocusListRequested")
}

// `ViewOptions` (sort + filter + display options of one scope, and the rules for editing them) lives
// in KronosCore/Contracts/ViewOptions.swift; the model persists one per scope. All evaluation goes
// through Core (`KTaskSorter`, `KFilter.matches`).

/// The single shared UI state object. Created once by the app shell and handed to
/// every screen. `@Observable`: views re-render on the properties they read.
@MainActor
@Observable
final class AppModel {
    let store: TaskStore

    /// What the list shows. Sidebar writes, list reads.
    var scope: ListScope = .inbox
    /// The task open in the inspector. List writes, inspector reads.
    var selectedTaskID: UUID?
    /// A subtask of `selectedTaskID` shown in the inspector's subtask mode, else nil. Ignored
    /// (and cleared by the inspector) once the selected task is not its parent.
    var inspectedSubtaskID: UUID?
    /// Multi-selection (⌘/⇧ click, ⌘A in the list). Empty unless 2+ rows are selected; when
    /// not empty it always contains `selectedTaskID`, which stays the anchor. Not persisted.
    var selectedIDs: Set<UUID> = []
    /// Sidebar display mode. Persisted.
    var sidebarIconsOnly: Bool = false
    /// Colour mode. Persisted. Screens never branch on
    /// it: they pass it down as `.environment(\.chromaMode, …)` and the design system resolves tints.
    var chromaMode: ChromaMode = .focus { didSet { persist() } }
    /// An explicitly pinned focus task (key F / Impuls Start). Validate against the store on
    /// `version` change; cleared when the task is completed or deleted. Persisted.
    var pinnedFocusTaskID: UUID? { didSet { persist() } }
    /// THE task the user is working on: the pin, else the automatic Ordo task. The only thing
    /// that carries hue in Focus mode; what the Now card and the menu bar show.
    var focusTaskID: UUID? { pinnedFocusTaskID ?? ordoFocus.taskID }
    /// Free-text search of the current list. Not persisted.
    var searchText: String = ""
    /// Transient overlays owned by the shell. Impuls is opened from the
    /// sidebar's Impuls row / menu; the command palette from ⌘K. Neither is persisted.
    var isImpulsOpen: Bool = false
    /// Triage flow (one task at a time, suggestion prefilled): Kronos/Triage/TriageFlowView.swift.
    var isTriageOpen: Bool = false
    /// Time Blocks overlay (Kronos/TimeBlocks/**): only reachable when
    /// `TimeBlocksPrefs.isEnabled`; the sidebar row and its own hotkey both just set this.
    var isTimeBlocksOpen: Bool = false
    var isPaletteOpen: Bool = false
    /// Shortcuts card; lives on the model so overlays below it (triage) can yield the keyboard.
    var isKeymapOpen: Bool = false
    /// Note-link picker sheet, hosted by the shell (always mounted) so it outlives the inspector pane.
    var noteLinkPickerOpen: Bool = false
    /// Capture (paste notes -> proposed tasks) overlay, owned by the shell.
    var isCaptureOpen: Bool = false
    /// True while any shell overlay (scrim + card) is up; menu commands that act on the list
    /// beneath the scrim (⌘N inline row) must bail out instead of focusing behind it.
    var isAnyOverlayOpen: Bool {
        isImpulsOpen || isTriageOpen || isTimeBlocksOpen || isPaletteOpen || isKeymapOpen || isCaptureOpen
    }
    /// Text handed to Capture from outside the window (menu-bar meeting capture, Siri, a project
    /// folder). Capture reads it ONCE when it opens and clears it. Use `openCapture(with:)`.
    var pendingCaptureText: String?
    /// The AI router (nil = AI off / not configured: every AI feature falls back to its
    /// deterministic path). Set once by the app delegate; snapshots inject fixtures.
    var ai: (any AIRouting)?
    /// Bumped after ANY store mutation so computed lists refresh (SwiftData models are read
    /// through manual fetches, not @Query). Call `didMutate()`; never write `version` directly.
    private(set) var version: Int = 0
    /// First task of the open list under its current sort + filter — what the menu bar shows
    /// (automatic Ordo). The list screen publishes it; the menu-bar screen reads it.
    private(set) var ordoFocus: OrdoFocus = .empty(listName: "")
    /// Top of the list currently shown (name + first ids). "next" is its first eligible row, so
    /// browsing another list changes it by design. Published by the list screen.
    private(set) var shownListHead: ShownListHead = .empty

    /// The coach (settings, Ordo presets, calendar blocks). See CoachModel.swift.
    private(set) var coach: CoachModel!
    /// Apple Notes bridge (read-only). Missing consent surfaces as a thrown error; UI shows a calm
    /// "Allow access" state for `.notAuthorised` and `.timedOut` alike.
    var notes: any AppleNotesBridge

    private var optionsByScope: [String: ViewOptions] = [:]

    init(store: TaskStore) {
        self.store = store
        // A live UI test run (KRONOS_STORE_DIR / KRONOS_UITEST) must never shell out to
        // `osascript`/Notes.app the way `OsaScriptNotesBridge` does — same hermetic reasoning
        // CoachModel.swift applies to its own calendar bridge. FixtureNotesBridge (Core) is a
        // no-op double: empty folders, nothing to fetch.
        let env = ProcessInfo.processInfo.environment
        let hermetic = env["KRONOS_STORE_DIR"] != nil || env["KRONOS_UITEST"] != nil
        self.notes = hermetic ? FixtureNotesBridge() : OsaScriptNotesBridge()
        restore()
        self.coach = CoachModel(model: self)
    }

    // MARK: Mutation + refresh

    /// Call after every store mutation made from the UI.
    func didMutate() {
        validatePin()
        version &+= 1
    }

    /// One user write: refresh every list and say what happened on the undo pill (⌘Z and the
    /// pill's Undo revert it). Every user-initiated store write goes through this, so "did that
    /// happen?" is always answered the same way; `didMutate()` alone is for refreshes nobody asked
    /// for (an external change, a lingering row leaving).
    func commit(_ message: String) {
        didMutate()
        UndoToastCenter.shared.show(message)
    }

    /// A pin never outlives its task: done, deleted or gone clears it, so the automatic Ordo task
    /// takes over. Runs here because every UI mutation and every external change funnels through
    /// `didMutate()`, whichever screens are mounted.
    private func validatePin() {
        guard let id = pinnedFocusTaskID else { return }
        if let t = store.task(id), t.status != .done, t.deletedAt == nil { return }
        pinnedFocusTaskID = nil
    }

    /// Called by the list whenever its first visible row (or its emptiness) changes.
    func publishOrdoFocus(_ focus: OrdoFocus) {
        guard focus != ordoFocus else { return }
        ordoFocus = focus
        NotificationCenter.default.post(name: .kronosOrdoFocusDidChange, object: nil)
    }

    /// Called by the list whenever the head of its rows changes. No-op when unchanged.
    func publishShownListHead(_ head: ShownListHead) {
        guard head != shownListHead else { return }
        shownListHead = head
    }

    /// The first eligible task of the shown list head (pin first), nil when the head holds none.
    var nextFromShownList: KTask? {
        Self.next(from: shownListHead, pinned: pinnedFocusTaskID, store: store)
    }

    static func next(from head: ShownListHead, pinned: UUID?, store: TaskStore) -> KTask? {
        let lookup = store.allTasks()
        let rows = head.ids.compactMap { id in lookup.first { $0.id == id } }
        return NextEligibility.pick(pinned: pinned, rows: rows, lookup: lookup)
    }

    /// The list a normal launch opens on, counted from the store (Today, then Inbox, then All).
    static func launchScopeChoice(store: TaskStore, hermetic: Bool, today: Int) -> LaunchScopeChoice {
        let tasks = store.allTasks()
        func open(_ scope: ListScope) -> Int {
            tasks.filter { KStatus.open.contains($0.status) && ScopeFilter.matches($0, scope: scope, today: today) }.count
        }
        return LaunchScope.pick(hermetic: hermetic, inboxOpen: open(.inbox), todayOpen: open(.today))
    }

    /// Open Capture with text already pasted (nil = empty).
    func openCapture(with text: String? = nil) {
        pendingCaptureText = text
        isCaptureOpen = true
    }

    // MARK: Per-scope view options

    /// What the list of `scope` shows: the options set on it, else the open saved view's own sort,
    /// filter and display switch (so editing a saved view's options changes the list it shows), else
    /// the defaults.
    func options(for scope: ListScope) -> ViewOptions {
        if let own = optionsByScope[scope.storageKey] { return own }
        if case .savedView(let id) = scope, let view = store.allSavedViews().first(where: { $0.id == id }) {
            return ViewOptions(sort: view.sortDescriptors, filter: view.filter, showCompleted: view.showDone)
        }
        return .default
    }

    func setOptions(_ options: ViewOptions, for scope: ListScope) {
        optionsByScope[scope.storageKey] = options
        persist()
    }

    // MARK: Persistence (UserDefaults; small, non-relational UI state only)

    private static let optionsKey = "kronos.ui.viewOptions.v1"
    private static let sidebarKey = "kronos.ui.sidebarIconsOnly"
    private static let scopeKey = "kronos.ui.scope.v1"
    private static let chromaKey = "kronos.ui.chromaMode"
    private static let pinKey = "kronos.ui.pinnedFocusTaskID"

    /// Snapshot runs are hermetic: they neither read nor write the real preferences domain
    /// (view options and scope were once found leaking between harness runs and into the
    /// real defaults).
    /// Also hermetic on a scratch store (KRONOS_STORE_DIR): a test run never edits real preferences.
    private static var isHermetic: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["KRONOS_SNAPSHOT"] != nil || env["KRONOS_STORE_DIR"] != nil
    }

    func persist() {
        guard !Self.isHermetic else { return }
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(optionsByScope) { d.set(data, forKey: Self.optionsKey) }
        if let data = try? JSONEncoder().encode(scope) { d.set(data, forKey: Self.scopeKey) }
        d.set(sidebarIconsOnly, forKey: Self.sidebarKey)
        d.set(chromaMode.rawValue, forKey: Self.chromaKey)
        d.set(pinnedFocusTaskID?.uuidString, forKey: Self.pinKey)
    }

    private func restore() {
        guard !Self.isHermetic else { return }
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.optionsKey),
           let v = try? JSONDecoder().decode([String: ViewOptions].self, from: data) { optionsByScope = v }
        if let data = d.data(forKey: Self.scopeKey),
           let s = try? JSONDecoder().decode(ListScope.self, from: data) { scope = s }
        sidebarIconsOnly = d.bool(forKey: Self.sidebarKey)
        chromaMode = d.string(forKey: Self.chromaKey).flatMap(ChromaMode.init(rawValue:)) ?? .focus
        pinnedFocusTaskID = d.string(forKey: Self.pinKey).flatMap(UUID.init(uuidString:))
    }
}
