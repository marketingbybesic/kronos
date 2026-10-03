// An undated task is an open todo in the Inbox (no due day, no project) on every creation path
// that goes through ListScopeDefaults. Someday stays a deliberate choice.

import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct InboxDefaultTests {

    /// Mirrors what the Inbox list shows (Kronos/Shared/ScopeFilter.swift, `.inbox`), written
    /// out by hand: no project, not Someday, open.
    private func isInInbox(_ t: KTask) -> Bool {
        t.projectID == nil && t.status != .someday && KStatus.open.contains(t.status)
    }

    @Test func undatedCreateWithTheScopeDefaultsLandsInTheInbox() throws {
        let store = try TaskStore(inMemory: true)
        for scope: QuickAddScopeKind? in [nil, .inbox, .all] {
            let d = ListScopeDefaults.apply(scope: scope, explicitDueDay: nil, today: Day.today())
            let t = store.create(title: "Undated", status: d.status, dueDay: d.dueDay)
            #expect(t.status == .todo)
            #expect(t.dueDay == nil)
            #expect(t.project == nil)
            #expect(isInInbox(t))
        }
    }

    @Test func capturedUndatedTaskIsAnOpenTodoNotSomeday() throws {
        let store = try TaskStore(inMemory: true)
        let created = store.createMany([
            ProposedTask(title: "No date", sourceLine: "No date"),
            ProposedTask(title: "Dated", dueDay: Day.today() + 4, sourceLine: "Dated"),
        ])
        #expect(created.map(\.status) == [.todo, .todo])
        #expect(created.map(\.dueDay) == [nil, Day.today() + 4])
        #expect(isInInbox(created[0]))
    }

    /// Existing Someday rows are never touched by the retired catch-up.
    @Test func aSomedayRowStaysSomeday() throws {
        let store = try TaskStore(inMemory: true)
        let s = store.createNoUndo(title: "Parked", status: .someday)
        let u = store.createNoUndo(title: "Undated open")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("KRONOS_STORE_DIR", dir.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }
        _ = UndatedSomedayMigration.runIfNeeded(store: store)
        #expect(store.task(s.id)?.status == .someday)
        #expect(store.task(u.id)?.status == .todo)
        #expect(!isInInbox(store.task(s.id)!))
    }

    /// Positive control: the old rule (undated -> Someday) is NOT what apply returns, so these
    /// tests fail against the previous behaviour.
    @Test func undatedIsNoLongerSomeday() {
        #expect(ListScopeDefaults.apply(scope: nil, explicitDueDay: nil, today: 20_000).status != .someday)
    }
}
