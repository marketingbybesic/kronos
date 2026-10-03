// Kronos/Intents/IntentActions.swift
//
// Every intent's real logic lives here, behind two tiny protocols that describe only the
// slice of behaviour an intent needs — never `KronosCore.TaskStoring` or `AppModel`
// directly — so this file imports Foundation ONLY. That lets `scripts/verify-intents.mjs`
// compile it with a bare `swiftc` (no KronosCore, no app target) against fixture
// conformances, and exercise AddTask / WhatsNext without booting SwiftData or AppKit.
//
// The real App Intents (AppIntentsKronos.swift) are thin: they resolve
// `AppDelegate.shared.model` / `.store`, wrap them in the small adapters at the bottom of
// this file, and hand off to `IntentActions`. All undo/notification/auto-triage behaviour
// comes for free because the adapters call straight through to `TaskStoring`.

import Foundation

/// The store surface an intent needs. Mirrors the handful of `TaskStoring` members
/// AddTask/WhatsNext/Complete/Pin touch — never a parallel write path.
@MainActor
public protocol IntentTaskStore {
    associatedtype TaskID: Hashable

    func intentAllOpenTasks() -> [IntentTaskFacts<TaskID>]
    func intentCreateTask(title: String, projectName: String?, priorityRaw: Int, dueDay: Int?) -> TaskID
    /// The full AddTask request (notes and a web link on top of the title fields). A store that does not
    /// carry notes or links keeps the default below, which creates the task from the title fields only.
    func intentCreateTask(_ request: IntentNewTask) -> TaskID
    func intentComplete(_ id: TaskID)
    func intentFirstMove(for id: TaskID) -> String?
}

public extension IntentTaskStore {
    func intentCreateTask(_ request: IntentNewTask) -> TaskID {
        intentCreateTask(title: request.title, projectName: request.projectName,
                         priorityRaw: request.priorityRaw, dueDay: request.dueDay)
    }
}

/// Everything AddTask can set. `notes` and `link` are already cleaned (`IntentNewTask.init`): blank notes and
/// a link that is not a plain http(s) URL become nil, so a store never receives an empty or broken reference.
public struct IntentNewTask: Equatable {
    public let title: String
    public let projectName: String?
    public let priorityRaw: Int
    public let dueDay: Int?
    public let notes: String?
    public let link: String?

    public init(title: String, projectName: String? = nil, priorityRaw: Int = 0, dueDay: Int? = nil,
                notes: String? = nil, link: String? = nil) {
        self.title = title
        self.projectName = projectName
        self.priorityRaw = priorityRaw
        self.dueDay = dueDay
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes
        self.link = IntentNewTask.webLink(link)
    }

    /// The URL as a string when it is http or https with a host, else nil.
    public static func webLink(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return raw
    }
}

/// A read-only projection of one task, just the fields an intent might report or rank on.
/// Generic over the id type so the real adapter can use `UUID` while the verify fixture
/// uses a trivial `Int`.
public struct IntentTaskFacts<ID: Hashable>: Equatable {
    public let id: ID
    public let title: String
    public let isOpen: Bool
    public let priority: Int
    public let dueDay: Int?
    public let ordoIndex: Double?
    public let projectName: String?
    public let notes: String

    public init(id: ID, title: String, isOpen: Bool, priority: Int, dueDay: Int?,
                ordoIndex: Double?, projectName: String?, notes: String = "") {
        self.notes = notes
        self.id = id
        self.title = title
        self.isOpen = isOpen
        self.priority = priority
        self.dueDay = dueDay
        self.ordoIndex = ordoIndex
        self.projectName = projectName
    }
}

/// The tiny slice of `AppModel` an intent needs: which task is in focus right now, and a
/// way to pin one. Kept separate from `IntentTaskStore` because focus is UI state
/// (`AppModel.pinnedFocusTaskID` / `.focusTaskID`), not a store fact.
@MainActor
public protocol IntentFocusModel {
    associatedtype TaskID: Hashable
    var intentFocusTaskID: TaskID? { get }
    func intentSetPinnedFocus(_ id: TaskID?)
}

/// Parses a quick-add-shaped string into a plain result an intent can act on, without
/// depending on `KronosCore.QuickAddParser` (which needs project names + a day number
/// this file has no business owning). The real intent still calls `QuickAddParser` itself
/// for the "#project @label !priority" grammar; this only extracts the parts every intent
/// caller needs to decide whether to bail early.
public enum IntentQuickAdd {
    /// True when, after trimming, there is nothing to create.
    public static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - IntentActions

/// Pure, synchronous logic for every intent. No AppIntents import here on purpose: this
/// type is exercised directly by `verify-intents.mjs`'s fixture executable and by the real
/// intents alike, so a change to the ranking or fallback rule is tested in exactly one
/// place.
@MainActor
public enum IntentActions {

    /// AddTask: create the task (auto-triage then runs on its own, through the store's
    /// existing creation notification — see AppDelegate/AutoTriage). Returns the new id and
    /// a short confirmation string Siri can speak.
    public static func addTask<S: IntentTaskStore>(
        store: S, title: String, projectName: String?, priorityRaw: Int, dueDay: Int?
    ) -> (id: S.TaskID, confirmation: String)? {
        guard !IntentQuickAdd.isBlank(title) else { return nil }
        let id = store.intentCreateTask(title: title, projectName: projectName,
                                        priorityRaw: priorityRaw, dueDay: dueDay)
        return (id, title)
    }

    /// AddTask with notes, a due day and a link. Same blank-title refusal as `addTask(store:title:...)`.
    public static func addTask<S: IntentTaskStore>(
        store: S, request: IntentNewTask
    ) -> (id: S.TaskID, confirmation: String)? {
        guard !IntentQuickAdd.isBlank(request.title) else { return nil }
        return (store.intentCreateTask(request), request.title)
    }

    /// CompleteTask: complete one task by id. Returns its title, or nil when the task is unknown or
    /// already closed (nothing is written then, so a repeated Shortcut run never re-completes).
    public static func completeTask<S: IntentTaskStore>(store: S, id: S.TaskID) -> String? {
        guard let task = store.intentAllOpenTasks().first(where: { $0.id == id && $0.isOpen }) else { return nil }
        store.intentComplete(id)
        return task.title
    }

    /// FindTasks: tasks whose title, notes or project name contain `text` (case and diacritics ignored),
    /// optionally inside one project and due on or before a day. Open tasks only unless `includeCompleted`.
    /// Order: open before closed, then the Ordo order (unranked last), then due day, then title.
    public static func findTasks<S: IntentTaskStore>(
        store: S, text: String?, projectName: String?, dueOnOrBefore: Int?,
        includeCompleted: Bool, limit: Int
    ) -> [IntentTaskFacts<S.TaskID>] {
        let needle = text.map(fold) ?? ""
        let project = projectName.map(fold) ?? ""
        let hits = store.intentAllOpenTasks().filter { t in
            if !includeCompleted && !t.isOpen { return false }
            if !needle.isEmpty && !(fold(t.title).contains(needle) || fold(t.notes).contains(needle)
                                    || fold(t.projectName ?? "").contains(needle)) { return false }
            if !project.isEmpty && fold(t.projectName ?? "") != project { return false }
            if let limitDay = dueOnOrBefore {
                guard let due = t.dueDay, due <= limitDay else { return false }
            }
            return true
        }
        let sorted = hits.sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            if a.ordoIndex != b.ordoIndex { return (a.ordoIndex ?? .infinity) < (b.ordoIndex ?? .infinity) }
            if a.dueDay != b.dueDay { return (a.dueDay ?? Int.max) < (b.dueDay ?? Int.max) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Case, diacritics and the Croatian crossed d ignored, matching how the app searches.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// WhatsNext: the focus task's title + first move, or a calm fallback sentence when
    /// nothing is open. Mirrors `AppModel.focusTaskID` (pin wins, else the automatic Ordo
    /// pick the list already published) rather than re-deriving ranking here.
    public static func whatsNext<S: IntentTaskStore, F: IntentFocusModel>(
        store: S, focus: F, fallbackTitle: String, calmEmptySentence: String
    ) -> String where F.TaskID == S.TaskID {
        guard let id = focus.intentFocusTaskID,
              let task = store.intentAllOpenTasks().first(where: { $0.id == id && $0.isOpen })
        else { return calmEmptySentence }
        let move = store.intentFirstMove(for: id)
        let title = task.title.isEmpty ? fallbackTitle : task.title
        guard let move, !move.isEmpty else { return title }
        return "\(title). \(move)"
    }

    /// CompleteCurrentTask: complete the focus task through the store (undo-safe, plays the
    /// completion sound via the app's own notification observer). Returns the completed
    /// task's title for confirmation, or nil when nothing is focused or it is already
    /// closed — the `isOpen` check matters here specifically: unlike the real app, where
    /// `AppModel.didMutate()` unpins a completed focus task right after this call returns,
    /// this pure function has no such follow-up, so a second call with a stale focus id
    /// must not silently "complete" an already-done task again.
    public static func completeCurrentTask<S: IntentTaskStore, F: IntentFocusModel>(
        store: S, focus: F
    ) -> String? where F.TaskID == S.TaskID {
        guard let id = focus.intentFocusTaskID,
              let task = store.intentAllOpenTasks().first(where: { $0.id == id && $0.isOpen })
        else { return nil }
        store.intentComplete(id)
        return task.title
    }

    /// PinFocus: pin an explicit task as focus (same field Impuls "Start" writes), clearing
    /// any previous pin first so `AppModel.focusTaskID` always resolves unambiguously.
    public static func pinFocus<F: IntentFocusModel>(focus: F, taskID: F.TaskID) {
        focus.intentSetPinnedFocus(taskID)
    }
}
