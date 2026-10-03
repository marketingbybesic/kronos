// Kronos/Impuls/FocusStart.swift
// The one "begin this task" action, shared by Impuls' Start, the morning plan's Let's go (row 1) and
// the Now card's Start: cue, in progress, selected, pinned as the focus task. The list stays where it
// is: switching to the task's project at the moment of starting is a context switch nobody asked for.
import AppKit
import KronosCore

extension Notification.Name {
    /// Posted when Start was pressed on a task whose first move is only the generic placeholder, so the
    /// inspector can put the cursor in that task's notes. `userInfo["taskID"]` is the task's UUID.
    static let kronosFocusNotesRequested = Notification.Name("kronosFocusNotesRequested")
    /// Asks the shell to show the morning plan inline (the palette's "morning plan" row posts it).
    static let kronosMorningPlanRequested = Notification.Name("kronosMorningPlanRequested")
}

@MainActor
enum FocusStart {
    /// How a first-move link is opened. A live test swaps it to see which link Start picks without
    /// launching Mail or a browser.
    static var openLink: (ContextLink, AppModel) -> Void = { ContextLinkActions.open($0, model: $1) }

    /// `followFirstMove`: also open the first move's link, or ask for the notes when the move is
    /// generic. Off for the morning plan, which only starts the first row.
    static func begin(_ task: KTask, model: AppModel, followFirstMove: Bool) {
        KronosSounds.play(.impuls)   // the one "go" cue; honours Settings > General > Sounds
        if task.status != .inProgress { model.store.setStatus(task.id, .inProgress) }
        model.selectedTaskID = task.id
        // Pinned, so the Now card, the sidebar tint and the menu bar all follow it.
        model.pinnedFocusTaskID = task.id
        model.didMutate()
        guard followFirstMove else { return }
        let language = Lang(rawValue: KronosLocale.languageCode) ?? .en
        if let link = ImpulsQuery.firstMoveLink(for: task) {
            openLink(link, model)
        } else if ImpulsQuery.hero(for: task, language: language).startOpensNotes {
            NotificationCenter.default.post(name: .kronosFocusNotesRequested, object: nil,
                                            userInfo: ["taskID": task.id])
        }
    }

    /// "Not now" on the Now card: set the task aside for today and move the pin to the next open row
    /// of the list that is on screen. Nothing is written to the store.
    static func notNow(_ task: KTask, nextRowID: UUID?, model: AppModel) {
        ImpulsDayMemory.setAside(task.id, today: Day.today(calendar: KronosLocale.calendar))
        model.pinnedFocusTaskID = nextRowID
        model.didMutate()
    }
}

/// The silent breakdown of a Large task with no steps: deterministic, no AI, no pill, no undo step
/// (a Cmd-Z must still undo what the person did, not this). Runs once per task.
@MainActor
enum ImpulsAutoBreakdown {
    @discardableResult
    static func runIfNeeded(_ task: KTask, store: TaskStore) -> Bool {
        guard ImpulsDefaults.shouldAutoBreakdown(effortRaw: task.effort.rawValue,
                                                 childCount: task.orderedChildren.count,
                                                 brokenBefore: ImpulsDayMemory.hadBreakdown(task.id)),
              !task.isSubtask, KStatus.open.contains(task.status) else { return false }
        let language = Lang(rawValue: KronosLocale.languageCode) ?? .en
        let result = DeterministicBreakdown.steps(title: task.title, notes: task.notes, language: language)
        ImpulsDayMemory.markBreakdown(task.id)
        for step in result.subtasks { _ = store.addSubtaskNoUndo(task.id, title: step) }
        return !result.subtasks.isEmpty
    }
}
