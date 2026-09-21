import Testing
import Foundation
@testable import KronosCore

/// rev 3: effort, project emoji, OrdoFocus and the decided undo window.
@MainActor
struct Rev3AttributeTests {

    private func store() throws -> TaskStore { try TaskStore(inMemory: true) }

    // MARK: - effort

    @Test func effortDefaultsToNoneAndRoundTrips() throws {
        let s = try store()
        let t = s.create(title: "T", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        #expect(t.effort == .none)
        #expect(t.effortRaw == 0)

        s.setEffort(t.id, .l)
        #expect(s.task(t.id)?.effort == .l)
        #expect(s.task(t.id)?.effortRaw == KEffort.l.rawValue)
        #expect(KEffort.allCases.count == 6)
    }

    @Test func effortIsCoveredByUndo() throws {
        let s = try store()
        let t = s.create(title: "T", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        s.setEffort(t.id, .xl)
        #expect(s.task(t.id)?.effort == .xl)

        // Would silently fail if effortRaw were missing from TaskSnapshot.
        // Unwrapped deliberately: `optional?.effort == .none` resolves `.none`
        // to `Optional.none`, so it asserts "not nil" and passes regardless
        // of the effort value.
        s.undo()
        #expect(try #require(s.task(t.id)).effort == KEffort.none)

        s.redo()
        #expect(s.task(t.id)?.effort == .xl)
    }

    @Test func setEffortNoUndoWritesWithoutTouchingTheUndoStack() throws {
        let s = try store()
        let t = s.create(title: "T", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let depth = s.undoDepth

        s.setEffortNoUndo(t.id, .m)
        #expect(s.task(t.id)?.effort == .m)
        #expect(s.undoDepth == depth)
    }

    @Test func effortIsIndependentOfDepthAndEstimate() throws {
        let s = try store()
        let t = s.create(title: "T", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        s.update(t.id) { $0.depth = .deep; $0.estimateMinutes = 120 }
        s.setEffort(t.id, .xs)

        // The ADHD engine still ranks on depth/estimate; effort changed none.
        #expect(s.task(t.id)?.depth == .deep)
        #expect(s.task(t.id)?.estimateMinutes == 120)
        #expect(s.task(t.id)?.effort == .xs)
    }

    @Test func effortIsInTheV1Schema() {
        // Added straight to V1 (placeholder data only), so no migration stage.
        #expect(KronosMigrationPlan.stages.isEmpty)
        #expect(KronosSchemaV1.models.contains { $0 == KTask.self })
    }

    // MARK: - project emoji

    @Test func projectEmojiIsOptionalAndEditable() throws {
        let s = try store()
        let p = s.createProject(name: "Acme", colorHex: "#3FB950", icon: "leaf", area: nil)
        #expect(p.emoji == nil)

        s.updateProject(p.id, emoji: .some("🌵"))
        #expect(s.allProjects().first { $0.id == p.id }?.emoji == "🌵")

        // .some(nil) clears it; a bare nil argument leaves it alone.
        s.updateProject(p.id, name: "Acme Bistro")
        #expect(s.allProjects().first { $0.id == p.id }?.emoji == "🌵")
        #expect(s.allProjects().first { $0.id == p.id }?.name == "Acme Bistro")

        s.updateProject(p.id, emoji: .some(nil))
        #expect(s.allProjects().first { $0.id == p.id }?.emoji == nil)
    }

    @Test func updateProjectChangesColourWithoutTouchingOtherFields() throws {
        let s = try store()
        let p = s.createProject(name: "Globex", colorHex: "#8224E3", icon: "circle", area: nil)
        s.updateProject(p.id, colorHex: "#3FB950")
        let back = try #require(s.allProjects().first { $0.id == p.id })
        #expect(back.colorHex == "#3FB950")
        #expect(back.name == "Globex")
        #expect(back.icon == "circle")
    }

    // MARK: - OrdoFocus

    @Test func ordoFocusCarriesWhatTheMenuBarRenders() {
        let id = UUID()
        let f = OrdoFocus(taskID: id, title: "Nazvati Karla",
                          firstMove: "Otvoriti imenik.",
                          listName: "Today", remaining: 4)
        #expect(f.taskID == id)
        #expect(!f.isEmpty)
        #expect(f.listName == "Today")
        #expect(f.remaining == 4)
        #expect(f == OrdoFocus(taskID: id, title: "Nazvati Karla",
                               firstMove: "Otvoriti imenik.",
                               listName: "Today", remaining: 4))
    }

    @Test func emptyOrdoFocusIsARealState() {
        let f = OrdoFocus.empty(listName: "Today")
        #expect(f.isEmpty)
        #expect(f.taskID == nil)
        #expect(f.remaining == 0)
        #expect(f.listName == "Today")
    }

    @Test func ordoFocusNotificationNameExists() {
        #expect(Notification.Name.kronosOrdoFocusDidChange.rawValue == "kronosOrdoFocusDidChange")
        // The rev 1 names are untouched.
        #expect(Notification.Name.kronosDidCompleteFromBar.rawValue == "kronosDidCompleteFromBar")
        #expect(Notification.Name.kronosDayDidChange.rawValue == "kronosDayDidChange")
    }

    @Test func ordoStoreMethodsStillWorkButAreNotExpanded() throws {
        // rev 3 left ordoIndex and the ordo methods in place deliberately;
        // this pins that they still function so no schema churn was needed.
        let s = try store()
        let t = s.create(title: "T", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        s.sendToOrdo(t.id, top: false)
        #expect(s.task(t.id)?.ordoIndex != nil)
        s.removeFromOrdo(t.id)
        #expect(s.task(t.id)?.ordoIndex == nil)
    }

    // MARK: - timing

    @Test func undoWindowIsFiveSecondsEverywhere() {
        // SPEC §12.4 open item 2, decided: 5 s, not 3 s.
        #expect(KronosTiming.undoWindowSeconds == 5)
    }
}
