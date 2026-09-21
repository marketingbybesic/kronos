import Testing
import Foundation
@testable import KronosCore

/// KFilter (rev 3): every field constrainable independently, combined with AND.
@MainActor
struct FilterTests {

    private func store() throws -> TaskStore { try TaskStore(inMemory: true) }
    private let today = 1000

    @Test func emptyFilterMatchesEverything() throws {
        let s = try store()
        let t = s.create(title: "anything", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        #expect(KFilter.empty.matches(t, today: today))
    }

    @Test func emptyCollectionMeansUnconstrainedNotMatchNothing() throws {
        let s = try store()
        let t = s.create(title: "x", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        var f = KFilter()
        f.statuses = []
        f.priorities = []
        f.efforts = []
        #expect(f.matches(t, today: today))
    }

    @Test func softDeletedRowsNeverMatch() throws {
        let s = try store()
        let t = s.create(title: "gone", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        s.softDelete(t.id)
        let live = try #require(s.taskIncludingDeleted(t.id))
        // Letting a deleted row through would resurrect it in every list.
        #expect(!KFilter.empty.matches(live, today: today))
    }

    @Test func fieldsCombineWithAND() throws {
        let s = try store()
        let hit = s.create(title: "hit", notes: "", project: nil, status: .todo, priority: .high, dueDay: nil)
        s.setEffort(hit.id, .s)
        let wrongPriority = s.create(title: "miss", notes: "", project: nil, status: .todo, priority: .low, dueDay: nil)
        s.setEffort(wrongPriority.id, .s)

        var f = KFilter()
        f.statuses = [KStatus.todo.rawValue]
        f.priorities = [KPriority.high.rawValue]
        f.efforts = [KEffort.s.rawValue]

        #expect(f.matches(hit, today: today))
        #expect(!f.matches(wrongPriority, today: today))
    }

    @Test func projectFilterOrsWithNoProject() throws {
        let s = try store()
        let p = s.createProject(name: "Acme", colorHex: "#3FB950", icon: "leaf", area: nil)
        let inProject = s.create(title: "a", notes: "", project: p, status: .todo, priority: .none, dueDay: nil)
        let inbox = s.create(title: "b", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)

        var byID = KFilter(); byID.projectIDs = [p.id]
        #expect(byID.matches(inProject, today: today))
        #expect(!byID.matches(inbox, today: today))

        var byNone = KFilter(); byNone.noProject = true
        #expect(!byNone.matches(inProject, today: today))
        #expect(byNone.matches(inbox, today: today))

        // "Inbox OR Acme" is expressible.
        var both = KFilter(); both.projectIDs = [p.id]; both.noProject = true
        #expect(both.matches(inProject, today: today))
        #expect(both.matches(inbox, today: today))
    }

    @Test func labelFilterIsAnyOf() throws {
        let s = try store()
        let urgent = s.label(named: "urgent")
        let home = s.label(named: "home")
        let t = s.create(title: "a", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        s.update(t.id) { $0.labels = [urgent] }

        var f = KFilter(); f.labelIDs = [urgent.id, home.id]
        #expect(f.matches(t, today: today))

        var miss = KFilter(); miss.labelIDs = [home.id]
        #expect(!miss.matches(t, today: today))
    }

    @Test func deadlineWindows() throws {
        let s = try store()
        let overdue = s.create(title: "o", notes: "", project: nil, status: .todo, priority: .none, dueDay: today - 3)
        let dueToday = s.create(title: "t", notes: "", project: nil, status: .todo, priority: .none, dueDay: today)
        let inFive = s.create(title: "5", notes: "", project: nil, status: .todo, priority: .none, dueDay: today + 5)
        let inTwenty = s.create(title: "20", notes: "", project: nil, status: .todo, priority: .none, dueDay: today + 20)
        let undated = s.create(title: "n", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)

        var f = KFilter()

        f.due = .overdue
        #expect(f.matches(overdue, today: today))
        #expect(!f.matches(dueToday, today: today))
        #expect(!f.matches(undated, today: today))

        f.due = .today
        // Carried tasks still read as "today" — the original date survives.
        #expect(f.matches(overdue, today: today))
        #expect(f.matches(dueToday, today: today))
        #expect(!f.matches(inFive, today: today))

        f.due = .next7
        #expect(f.matches(inFive, today: today))
        #expect(!f.matches(inTwenty, today: today))
        #expect(!f.matches(overdue, today: today))

        f.due = .next30
        #expect(f.matches(inTwenty, today: today))

        f.due = .none
        #expect(f.matches(undated, today: today))
        #expect(!f.matches(dueToday, today: today))

        f.due = .custom
        f.dueFrom = today + 1
        f.dueTo = today + 10
        #expect(f.matches(inFive, today: today))
        #expect(!f.matches(inTwenty, today: today))
        #expect(!f.matches(dueToday, today: today))
        #expect(!f.matches(undated, today: today))
    }

    @Test func thisWeekKeepsItsV1MeaningAsNext7() throws {
        let s = try store()
        let inFive = s.create(title: "5", notes: "", project: nil, status: .todo, priority: .none, dueDay: today + 5)
        let inTwenty = s.create(title: "20", notes: "", project: nil, status: .todo, priority: .none, dueDay: today + 20)
        let undated = s.create(title: "n", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)

        var week = KFilter(); week.due = .thisWeek
        var seven = KFilter(); seven.due = .next7
        // A saved view written before rev 3 must not quietly change meaning.
        for t in [inFive, inTwenty, undated] {
            #expect(week.matches(t, today: today) == seven.matches(t, today: today))
        }
        #expect(week.matches(inFive, today: today))
        #expect(!week.matches(inTwenty, today: today))
    }

    @Test func customWindowWithNoBoundsStillRequiresADeadline() throws {
        let s = try store()
        let undated = s.create(title: "n", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let dated = s.create(title: "d", notes: "", project: nil, status: .todo, priority: .none, dueDay: today)

        var f = KFilter(); f.due = .custom   // both bounds left nil
        #expect(!f.matches(undated, today: today))
        #expect(f.matches(dated, today: today))
    }

    @Test func booleanFieldsDistinguishTrueFalseAndUnset() throws {
        let s = try store()
        let withNotes = s.create(title: "a", notes: "some notes", project: nil, status: .todo, priority: .none, dueDay: nil)
        let bare = s.create(title: "b", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        _ = s.addSubtask(withNotes.id, title: "step")

        var f = KFilter()
        f.hasNotes = true
        #expect(f.matches(withNotes, today: today))
        #expect(!f.matches(bare, today: today))

        f.hasNotes = false
        #expect(!f.matches(withNotes, today: today))
        #expect(f.matches(bare, today: today))

        // nil = do not constrain
        f.hasNotes = nil
        #expect(f.matches(withNotes, today: today))
        #expect(f.matches(bare, today: today))

        var g = KFilter(); g.hasSubtasks = true
        #expect(g.matches(withNotes, today: today))
        #expect(!g.matches(bare, today: today))

        var n = KFilter(); n.needsTriage = true
        #expect(n.matches(bare, today: today))   // new tasks need triage
    }

    @Test func textSearchFoldsDiacriticsIncludingDj() throws {
        let s = try store()
        let t = s.create(title: "Posjet Đakovu", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)

        var f = KFilter()
        f.text = "dakovu"     // typed without the stroke
        #expect(f.matches(t, today: today))

        f.text = "ĐAKOVU"
        #expect(f.matches(t, today: today))

        f.text = "zagreb"
        #expect(!f.matches(t, today: today))
    }

    @Test func textSearchCoversNotes() throws {
        let s = try store()
        let t = s.create(title: "Call", notes: "about the Globex bond", project: nil, status: .todo, priority: .none, dueDay: nil)
        var f = KFilter(); f.text = "globex"
        #expect(f.matches(t, today: today))
    }

    // MARK: - persistence / compatibility

    @Test func filterRoundTripsThroughItsEncodedString() throws {
        var f = KFilter()
        f.statuses = [0, 1]
        f.efforts = [KEffort.l.rawValue]
        f.areaIDs = [UUID()]
        f.noProject = true
        f.due = .custom
        f.dueFrom = 10
        f.dueTo = 20
        f.hasNotes = true
        f.text = "globex"

        let back = KFilter.decode(f.encodedString)
        #expect(back == f)
    }

    @Test func aV1BlobStillDecodes() throws {
        // What an older build wrote: none of the rev 3 keys are present.
        let v1 = #"{"v":1,"statuses":[0],"priorities":[],"projectIDs":[],"labelIDs":[],"due":"today","depths":[],"text":"x"}"#
        let f = KFilter.decode(v1)
        #expect(f.statuses == [0])
        #expect(f.due == .today)
        #expect(f.text == "x")
        // rev 3 fields take their defaults rather than throwing.
        #expect(f.efforts.isEmpty)
        #expect(f.noProject == false)
        #expect(f.hasNotes == nil)
    }

    @Test func anUndecodableBlobFallsBackToEmpty() {
        #expect(KFilter.decode("not json") == .empty)
        #expect(KFilter.decode("{}") == .empty)
    }
}
