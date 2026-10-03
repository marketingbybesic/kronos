import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// Two stores that grew apart, merged into one (what the first sync does): every duplicate is
/// folded into the oldest row, references follow it, and a second sweep finds nothing.
@MainActor
@Suite("DedupeSweepTests")
struct DedupeSweepTests {

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private func area(_ s: TaskStore, _ name: String, created: Double) -> KArea {
        let a = KArea(name: name)
        a.createdAt = Self.at(created)
        s.context.insert(a)
        return a
    }

    private func project(_ s: TaskStore, _ name: String, area: KArea?, created: Double) -> KProject {
        let p = KProject(name: name, area: area)
        p.createdAt = Self.at(created)
        s.context.insert(p)
        return p
    }

    private func label(_ s: TaskStore, _ name: String, created: Double) -> KLabel {
        let l = KLabel(name: name)
        l.createdAt = Self.at(created)
        s.context.insert(l)
        return l
    }

    private func task(_ s: TaskStore, _ title: String, project: KProject? = nil, labels: [KLabel] = [],
                      created: Double, updated: Double? = nil, id: UUID = UUID()) -> KTask {
        let t = KTask(title: title, project: project)
        t.id = id
        t.labels = labels
        t.createdAt = Self.at(created)
        t.updatedAt = Self.at(updated ?? created)
        s.context.insert(t)
        return t
    }

    /// The Mac's store plus what a fresh iPhone made on its own before the first sync.
    @Test func mergedStoreFoldsEveryDuplicate() throws {
        let s = try TaskStore(inMemory: true)
        // Mac
        let work = area(s, "Work", created: 0)
        let offers = project(s, "Offers", area: work, created: 1)
        let urgent = label(s, "Urgent", created: 2)
        let macTask = task(s, "Send the offer", project: offers, labels: [urgent], created: 3)
        // iPhone, same names typed differently
        let work2 = area(s, "  work ", created: 100)
        let offers2 = project(s, "OFFERS", area: work2, created: 101)
        let urgent2 = label(s, "urgent", created: 102)
        let phoneTask = task(s, "Call the supplier", project: offers2, labels: [urgent2], created: 103)
        phoneTask.areaID = work2.id
        // Not duplicates: other name, or the same project name in another area.
        let home = area(s, "Home", created: 5)
        let homeOffers = project(s, "Offers", area: home, created: 6)
        let view = KSavedView(name: "Phone offers", filter: KFilter())
        view.filterJSON = "{\"projectIDs\":[\"\(offers2.id.uuidString)\"],\"labelIDs\":[\"\(urgent2.id.uuidString)\"]}"
        s.context.insert(view)
        try s.context.save()

        let report = DedupeSweep.run(in: s)
        #expect(report.areas == 1)
        #expect(report.projects == 1)
        #expect(report.labels == 1)
        #expect(report.tasks == 0)

        let areas = try s.context.fetch(FetchDescriptor<KArea>())
        #expect(Set(areas.map(\.id)) == [work.id, home.id])
        let projects = try s.context.fetch(FetchDescriptor<KProject>())
        #expect(Set(projects.map(\.id)) == [offers.id, homeOffers.id])
        let labels = try s.context.fetch(FetchDescriptor<KLabel>())
        #expect(labels.map(\.id) == [urgent.id])

        let phone = try #require(s.task(phoneTask.id))
        #expect(phone.project?.id == offers.id)
        #expect(phone.projectID == offers.id)
        #expect(phone.areaID == work.id)
        #expect((phone.labels ?? []).map(\.id) == [urgent.id])
        #expect(s.task(macTask.id)?.projectID == offers.id)
        #expect(view.filterJSON.contains(offers.id.uuidString))
        #expect(view.filterJSON.contains(urgent.id.uuidString))
        #expect(!view.filterJSON.contains(offers2.id.uuidString))

        // Idempotent.
        #expect(DedupeSweep.run(in: s).total == 0)
    }

    /// Two records with one task id: the oldest row stays, the newest content wins, labels are
    /// unioned, children and attachments move over, and a done copy keeps the task done.
    @Test func sameIDTasksBecomeOneRow() throws {
        let s = try TaskStore(inMemory: true)
        let a = label(s, "A", created: 0)
        let b = label(s, "B", created: 0)
        let id = UUID()
        let older = task(s, "Draft", labels: [a], created: 10, updated: 10, id: id)
        older.notes = "older notes"
        let newer = task(s, "Draft v2", labels: [b], created: 20, updated: 50, id: id)
        newer.notes = "newer notes"
        newer.statusRaw = KStatus.done.rawValue
        newer.completedAt = Self.at(49)
        let child = task(s, "Step", created: 21)
        child.parent = newer
        child.parentID = id
        let file = KAttachment(kindRaw: 0, title: "Spec", url: "https://example.com/spec")
        file.task = newer
        s.context.insert(file)
        try s.context.save()

        let report = DedupeSweep.run(in: s)
        #expect(report.tasks == 1)
        let rows = s.allTasksIncludingDeleted().filter { $0.id == id }
        #expect(rows.count == 1)
        let kept = try #require(rows.first)
        #expect(kept.createdAt == Self.at(10))          // the oldest row stays
        #expect(kept.title == "Draft v2")                // newest content
        #expect(kept.notes == "newer notes")
        #expect(Set((kept.labels ?? []).map(\.name)) == ["A", "B"])
        #expect(kept.status == .done)
        #expect(kept.orderedChildren.map(\.title) == ["Step"])
        #expect(s.task(child.id)?.parentID == id)
        #expect((kept.attachments ?? []).map(\.title) == ["Spec"])
        #expect(DedupeSweep.run(in: s).total == 0)
    }

    /// A pending undo step on a merged task id would put back a pre-merge value: it goes.
    @Test func undoStepsOnMergedTasksAreDropped() throws {
        let s = try TaskStore(inMemory: true)
        let id = UUID()
        _ = task(s, "Copy one", created: 10, id: id)
        let other = s.create(title: "Unrelated")
        try s.context.save()
        let base = s.undoDepth
        s.setPriority(id, .high)
        s.setPriority(other.id, .high)
        _ = task(s, "Copy two", created: 20, updated: 99, id: id)
        try s.context.save()
        DedupeSweep.run(in: s)
        #expect(s.undoDepth == base + 1)
        s.undo()
        #expect(s.task(other.id)?.priority == KPriority.none)
    }

    /// The older copy is the done one, the newer copy is open: still done (completion is never
    /// undone by a merge).
    @Test func doneWinsOverANewerOpenCopy() throws {
        let s = try TaskStore(inMemory: true)
        let id = UUID()
        let done = task(s, "Pay rent", created: 10, updated: 10, id: id)
        done.statusRaw = KStatus.done.rawValue
        done.completedAt = Self.at(10)
        _ = task(s, "Pay rent", created: 20, updated: 30, id: id)
        try s.context.save()
        DedupeSweep.run(in: s)
        let kept = try #require(s.allTasksIncludingDeleted().first { $0.id == id })
        #expect(kept.status == .done)
        #expect(kept.completedAt == Self.at(10))
    }

    /// Learned rules from two devices, and two marker rows for one key.
    @Test func rulesAndMarkersFold() throws {
        let s = try TaskStore(inMemory: true)
        let r1 = KRule(text: "Calls go in the afternoon", scope: .triage, source: .feedback)
        r1.createdAt = Self.at(0); r1.updatedAt = Self.at(0)
        let r2 = KRule(text: "  calls go in the AFTERNOON ", scope: .triage, source: .feedback)
        r2.createdAt = Self.at(5); r2.updatedAt = Self.at(9); r2.isActive = false
        let other = KRule(text: "Calls go in the afternoon", scope: .impuls, source: .manual)
        s.context.insert(r1); s.context.insert(r2); s.context.insert(other)
        s.context.insert(KStoreMeta(key: "migration.x", value: "1", updatedAt: Self.at(1)))
        s.context.insert(KStoreMeta(key: "migration.x", value: "2", updatedAt: Self.at(2)))
        try s.context.save()

        let report = DedupeSweep.run(in: s)
        #expect(report.rules == 1)
        #expect(report.markers == 1)
        let rules = s.allRules(includeInactive: true)
        #expect(Set(rules.map(\.id)) == [r1.id, other.id])
        #expect(rules.first { $0.id == r1.id }?.isActive == false)   // newest on/off state
        #expect(s.metaValue("migration.x") == "2")
        #expect(s.metaRows("migration.x").count == 1)
    }

    /// A pending undo step that would write a removed project is dropped; others stay.
    @Test func undoStepsOnRemovedRowsAreDropped() throws {
        let s = try TaskStore(inMemory: true)
        let keep = project(s, "Garden", area: nil, created: 0)
        let dup = project(s, "garden", area: nil, created: 9)
        let t = task(s, "Mow", created: 1)
        try s.context.save()
        s.updateProject(dup.id, name: "garden ")      // one step on the duplicate
        s.setPriority(t.id, .high)                    // one step on an unrelated task
        #expect(s.undoDepth == 2)
        DedupeSweep.run(in: s)
        #expect(s.undoDepth == 1)
        s.undo()
        #expect(s.task(t.id)?.priority == KPriority.none)
        #expect(s.allProjects(includeArchived: true).map(\.id) == [keep.id])
    }
}
