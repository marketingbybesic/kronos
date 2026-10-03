// Kronos/List/TodayClear.swift
// The empty Today: "Today is clear. N done." with a calm next step (Pick one), and the day-clear
// cue, played once on the move from a Today with rows to an empty one (DayClearCue).
import SwiftUI
import KronosCore

@MainActor
enum TodayClear {
    /// How many times the cue was asked for in this run; the live UI test reads it.
    private(set) static var cuesPlayed = 0

    /// Top-level tasks finished today.
    static func doneToday(_ store: TaskStore, today: Int = Day.today()) -> Int {
        store.allTasks().filter { task in
            guard task.status == .done, task.deletedAt == nil, !task.isSubtask, let at = task.completedAt else { return false }
            return Day.from(at) == today
        }.count
    }

    /// Rows of an unfiltered Today, or nil when the list is anything else (another scope, a
    /// search or filter rules narrowing it): only an unfiltered Today can "become clear".
    static func observedRows(_ ctx: ListContext, model: AppModel) -> Int? {
        guard model.scope == .today, model.searchText.isEmpty, ctx.activeRuleCount == 0 else { return nil }
        return ctx.totalCount
    }

    /// Records the new look and plays the cue on the transition. Returns the new observation.
    static func track(previous: Int?, _ ctx: ListContext, model: AppModel) -> Int? {
        let now = observedRows(ctx, model: model)
        if let now, DayClearCue.shouldPlay(previousRows: previous, nowRows: now, doneToday: doneToday(model.store)) {
            cuesPlayed += 1
            KronosSounds.play(.dayclear)
        }
        return now
    }
}

/// Today with nothing left to show.
struct TodayClearState: View {
    @Bindable var model: AppModel

    var body: some View {
        let done = TodayClear.doneToday(model.store)
        KEmptyState(icon: "sun",
                    title: done > 0 ? String(format: String(localized: "today.clear.done"), done)
                                    : String(localized: "today.clear.title"),
                    message: String(localized: "today.clear.hint"),
                    actionTitle: String(localized: "today.clear.action"),
                    onAction: { model.isImpulsOpen = true })
            .uiTestAnchor("today.clear")
    }
}
