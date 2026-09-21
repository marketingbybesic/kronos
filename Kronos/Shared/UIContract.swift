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

/// Sort + filter + display options of one scope. The list screen owns editing it; the model
/// persists it. All evaluation goes through Core (`KTaskSorter`, `KFilter.matches`).
struct ViewOptions: Codable, Equatable, Sendable {
    var sort: [KSortDescriptor] = KSortDescriptor.default
    var filter: KFilter = .empty
    var showCompleted: Bool = false

    static let `default` = ViewOptions()
}

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
    /// Capture (paste notes -> proposed tasks) overlay, owned by the shell.
    var isCaptureOpen: Bool = false
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

    /// Open Capture with text already pasted (nil = empty).
    func openCapture(with text: String? = nil) {
        pendingCaptureText = text
        isCaptureOpen = true
    }

    // MARK: Per-scope view options

    func options(for scope: ListScope) -> ViewOptions { optionsByScope[scope.storageKey] ?? .default }

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
