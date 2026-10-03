import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// The scalar mirrors follow the relationships after one side was changed alone (as a sync
/// delivering fields and references out of order would leave them).
@MainActor
@Suite("MirrorReconcileTests")
struct MirrorReconcileTests {

    private func fixture() throws -> (TaskStore, KArea, KProject, KProject, KTask, KTask) {
        let s = try TaskStore(inMemory: true)
        let area = KArea(name: "Work")
        let p1 = KProject(name: "Offers", area: area)
        let p2 = KProject(name: "Archive", area: nil)
        p2.isArchived = true
        s.context.insert(area); s.context.insert(p1); s.context.insert(p2)
        let parent = KTask(title: "Parent", project: p1)
        let child = KTask(title: "Child", project: p1)
        child.parent = parent
        child.parentID = parent.id
        s.context.insert(parent); s.context.insert(child)
        try s.context.save()
        return (s, area, p1, p2, parent, child)
    }

    @Test func untouchedStoreNeedsNothing() throws {
        let (s, _, _, _, _, _) = try fixture()
        #expect(MirrorReconcile.run(in: s) == 0)
    }

    /// Scalar changed, relationship not: the scalar goes back to what the relationship says.
    @Test func wrongScalarsFollowTheRelationship() throws {
        let (s, area, p1, _, parent, _) = try fixture()
        parent.projectID = UUID()
        parent.areaID = UUID()
        parent.isProjectArchived = true
        #expect(MirrorReconcile.run(in: s) == 1)
        #expect(parent.projectID == p1.id)
        #expect(parent.areaID == area.id)
        #expect(parent.isProjectArchived == false)
    }

    /// Relationship changed, scalar not: the scalars take the new project's values.
    @Test func newRelationshipWins() throws {
        let (s, _, _, p2, parent, child) = try fixture()
        let before = parent.updatedAt
        parent.project = p2
        #expect(MirrorReconcile.run(in: s) == 2)   // the parent, and its child follows it
        #expect(parent.projectID == p2.id)
        #expect(parent.areaID == nil)
        #expect(parent.isProjectArchived == true)
        #expect(child.project?.id == p2.id)
        #expect(child.projectID == p2.id)
        #expect(parent.updatedAt == before)         // derived values are not an edit
    }

    /// The parent link: a stale or missing parentID follows `parent`; a parentID with no
    /// parent relationship is cleared.
    @Test func parentMirrorFollowsTheParent() throws {
        let (s, _, _, _, parent, child) = try fixture()
        child.parentID = nil
        let orphanMirror = KTask(title: "Loose")
        orphanMirror.parentID = parent.id
        s.context.insert(orphanMirror)
        #expect(MirrorReconcile.run(in: s) == 2)
        #expect(child.parentID == parent.id)
        #expect(orphanMirror.parentID == nil)
    }

    /// A task in an area with no project keeps its own areaID (it is not a mirror then).
    @Test func areaOnlyTaskKeepsItsArea() throws {
        let (s, area, _, _, _, _) = try fixture()
        let t = KTask(title: "Area only")
        t.areaID = area.id
        s.context.insert(t)
        #expect(MirrorReconcile.run(in: s) == 0)
        #expect(t.areaID == area.id)
    }
}
