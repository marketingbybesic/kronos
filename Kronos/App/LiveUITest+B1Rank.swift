// Kronos/App/LiveUITest+B1Rank.swift
// Live steps for the launch-scope choice and the "next from the shown list" rule. Both run the
// real app code (ScopeFilter, NextEligibility, AppModel) against isolated in-memory stores, so
// the scratch store the rest of the suite uses is never touched. Compiled only outside Release.
#if !RELEASE
import Foundation
import KronosCore

@MainActor
extension LiveUITest {

    static func b1RankSteps(_ model: AppModel) async {
        let today = Day.today()
        // --break flips one expectation: the run must then fail.
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        guard let store = try? TaskStore(inMemory: true) else {
            record("launch scope: isolated store opens", false, "TaskStore(inMemory:) threw")
            return
        }
        func choice(hermetic: Bool = false) -> LaunchScopeChoice {
            AppModel.launchScopeChoice(store: store, hermetic: hermetic, today: today)
        }

        // Empty store: nothing open anywhere -> All.
        record("launch scope: an empty store opens All", choice() == .all, "choice=\(choice())")

        // Only an Inbox task: Inbox.
        let inbox = store.create(title: "rank.inbox")
        record("launch scope: Inbox-only work opens Inbox", choice() == .inbox, "choice=\(choice())")

        // A task due today as well: Today wins even though Inbox still has a task.
        let due = store.create(title: "rank.today")
        store.update(due.id) { $0.dueDay = today }
        record("launch scope: Today with open tasks opens Today, ahead of a non-empty Inbox",
               choice() == (breakMode ? .inbox : .today), "choice=\(choice())")
        record("launch scope: a hermetic run keeps Inbox",
               choice(hermetic: true) == .inbox, "choice=\(choice(hermetic: true))")

        // Today emptied: back to Inbox.
        store.complete(due.id)
        record("launch scope: Today emptied falls back to Inbox", choice() == .inbox, "choice=\(choice())")
        _ = inbox

        // Next = first eligible row of the shown list; the head caps at 8 ids.
        let done = store.create(title: "rank.done"); store.complete(done.id)
        let pending = store.create(title: "rank.pending"); store.update(pending.id) { $0.reviewRaw = 1 }
        let blocker = store.create(title: "rank.blocker")
        let blocked = store.create(title: "rank.blocked"); _ = store.setWaitsOn(blocked.id, [blocker.id])
        let ok = store.create(title: "rank.ok")
        let head = ShownListHead(listName: "Today", ids: [done.id, pending.id, blocked.id, ok.id])
        let next = AppModel.next(from: head, pinned: nil, store: store)
        record("next: skips done, review-pending and blocked rows of the shown list",
               next?.id == ok.id, "next=\(next?.title ?? "nil")")
        let pinned = AppModel.next(from: head, pinned: blocked.id, store: store)
        record("next: a pinned task wins over the list order",
               pinned?.id == blocked.id, "next=\(pinned?.title ?? "nil")")
        let none = AppModel.next(from: ShownListHead(listName: "Today", ids: [done.id, pending.id]), pinned: nil, store: store)
        record("next: a list with no eligible row has no next", none == nil, "next=\(none?.title ?? "nil")")
        let capped = ShownListHead(listName: "All", ids: (0..<12).map { _ in UUID() })
        record("shown list head keeps at most 8 ids", capped.ids.count == 8, "count=\(capped.ids.count)")

        // The model holds the published head and ignores an unchanged republish.
        let before = model.shownListHead
        model.publishShownListHead(head)
        let held = model.shownListHead == head
        model.publishShownListHead(before)
        record("shown list head: the model keeps what the list publishes", held,
               "held=\(held) restored=\(model.shownListHead == before)")
    }
}
#endif
