// Kronos/MenuBar/MenuBarFocusResolver.swift
// The one answer to "which task does the bar and the popover show": the current time block's
// first open task when block precedence applies, else the pin, else the first ELIGIBLE row of the
// list being shown (done, pending-review, blocked and archived rows are skipped, so a finished
// task at row 1 never stays "next"), else the list's own first row while no list is mounted yet.
// The bar and the popover both read this, so they can never disagree.
import Foundation
import KronosCore

@MainActor
enum MenuBarFocusResolver {
    static func taskID(model: AppModel) -> UUID? {
        if let blockID = TimeBlocksModel(model: model).blockFocusTaskID, model.store.task(blockID) != nil { return blockID }
        // Pin, then the first eligible row of the shown list: the shared resolver (NextEligibility.pick),
        // the same one MCP and the Snapshot use, so the bar, the popover and agents agree.
        if let next = model.nextFromShownList { return next.id }
        // A list is mounted and none of its head rows may be next: nothing is next.
        if !model.shownListHead.ids.isEmpty { return nil }
        // No list on screen (cold launch, menu bar only): the shared Today fallback.
        let today = Day.today(calendar: KronosLocale.calendar)
        return NextFallback.todayHead(store: model.store, today: today, limit: 1).first
    }

    /// Rows after the focus for the popover's Next section: eligible only, focus excluded.
    static func eligible(_ rows: [KTask], model: AppModel) -> [KTask] {
        let lookup = model.store.allTasks()
        return rows.filter { NextEligibility.isEligible($0, lookup: lookup) }
    }
}
