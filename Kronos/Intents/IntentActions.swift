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
    func intentComplete(_ id: TaskID)
    func intentFirstMove(for id: TaskID) -> String?
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

    public init(id: ID, title: String, isOpen: Bool, priority: Int, dueDay: Int?,
                ordoIndex: Double?, projectName: String?) {
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
