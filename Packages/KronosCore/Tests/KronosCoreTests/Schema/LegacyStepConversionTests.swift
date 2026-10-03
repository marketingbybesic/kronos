import Foundation
import SwiftData
import XCTest
@testable import KronosCore

/// The step -> child task conversion the V1 -> V2 stage runs, on a hand-written in-memory V1
/// store. Expectations are literal values, never derived from the conversion's output.
/// XCTest for the reason given on `SchemaV2MigrationTests` (V1 containers must not be alive
/// while the parallel Swift Testing run writes V2 rows).
final class LegacyStepConversionTests: XCTestCase {
    typealias V1 = KronosSchemaV1

    static let passportID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let chargerID  = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    static let goneID     = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
    static let orphanID   = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000004")!
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_790_003_600)
    static let now = Date(timeIntervalSince1970: 1_790_100_000)

    struct Fixture {
        let container: ModelContainer
        let ctx: ModelContext
        let home: V1.KProject
        let pack: V1.KTask, old: V1.KTask, solo: V1.KTask
    }

    private func emptyV1() throws -> ModelContainer {
        let schema = Schema(versionedSchema: V1.self)
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    /// Home: "Pack" (steps Charger, Passport), "Old" (deleted, step Gone), "Solo".
    /// Plus a detached step row with no task.
    private func fixture() throws -> Fixture {
        let container = try emptyV1()
        let ctx = ModelContext(container)
        let area = V1.KArea(name: "Life")
        ctx.insert(area)
        let home = V1.KProject(name: "Home", area: area)
        ctx.insert(home)
        let pack = V1.KTask(title: "Pack", project: home)
        let old = V1.KTask(title: "Old", project: home)
        old.deletedAt = Self.t0
        let solo = V1.KTask(title: "Solo")
        for t in [pack, old, solo] { ctx.insert(t) }

        func step(_ id: UUID, _ title: String, _ owner: V1.KTask?, sort: Double) -> V1.KSubtask {
            let s = V1.KSubtask(title: title, sortIndex: sort)
            s.id = id
            s.createdAt = Self.t0
            s.updatedAt = Self.t1
            s.task = owner
            ctx.insert(s)
            return s
        }
        let passport = step(Self.passportID, "Passport", pack, sort: 2048)
        passport.isDone = true
        let charger = step(Self.chargerID, "Charger", pack, sort: 1024)
        charger.dueDay = Day.parseISO("2026-10-10")
        charger.priorityRaw = 3
        charger.notes = "link://web|Shop|https://example.com"
        _ = step(Self.goneID, "Gone step", old, sort: 0)
        _ = step(Self.orphanID, "Detached", nil, sort: 0)
        try ctx.save()
        return Fixture(container: container, ctx: ctx, home: home, pack: pack, old: old, solo: solo)
    }

    private func steps(_ ctx: ModelContext) -> Int { (try? ctx.fetchCount(FetchDescriptor<V1.KSubtask>())) ?? -1 }
    private func task(_ ctx: ModelContext, _ id: UUID) throws -> V1.KTask {
        try XCTUnwrap(try ctx.fetch(FetchDescriptor<V1.KTask>(predicate: #Predicate { $0.id == id })).first)
    }

    func testConvertsEveryStepWithItsIdFieldsAndParent() throws {
        let f = try fixture()
        let result = try KronosSchemaV2Stage.convertLegacySteps(in: f.ctx, now: Self.now)
        XCTAssertEqual(result, .init(converted: 3, orphans: 1, alreadyTasks: 0))
        XCTAssertEqual(steps(f.ctx), 0)
        XCTAssertEqual(try f.ctx.fetchCount(FetchDescriptor<V1.KTask>()), 7)

        let kids = (f.pack.children ?? []).sorted { $0.sortIndex < $1.sortIndex }
        XCTAssertEqual(kids.map(\.title), ["Charger", "Passport"])
        XCTAssertEqual(kids.map(\.id), [Self.chargerID, Self.passportID])

        let charger = try task(f.ctx, Self.chargerID)
        XCTAssertEqual(charger.parentID, f.pack.id)
        XCTAssertEqual(charger.parent?.id, f.pack.id)
        XCTAssertEqual(charger.statusRaw, 0)
        XCTAssertNil(charger.completedAt)
        XCTAssertEqual(charger.dueDay.map(Day.iso), "2026-10-10")
        XCTAssertEqual(charger.originalDueDay.map(Day.iso), "2026-10-10")
        XCTAssertEqual(charger.priorityRaw, 3)
        XCTAssertEqual(charger.notes, "link://web|Shop|https://example.com")
        XCTAssertEqual(charger.sortIndex, 1024)
        XCTAssertEqual(charger.projectID, f.home.id)
        XCTAssertEqual(charger.areaID, f.home.area?.id)
        XCTAssertEqual(charger.createdAt, Self.t0)
        XCTAssertEqual(charger.updatedAt, Self.t1)
        XCTAssertFalse(charger.needsTriage)

        let passport = try task(f.ctx, Self.passportID)
        XCTAssertEqual(passport.statusRaw, 4)
        XCTAssertEqual(passport.completedAt, Self.t1)

        let gone = try task(f.ctx, Self.goneID)
        XCTAssertEqual(gone.parentID, f.old.id)
        XCTAssertEqual(gone.deletedAt, Self.t0, "a deleted task's step is deleted with the same stamp")

        let orphan = try task(f.ctx, Self.orphanID)
        XCTAssertNil(orphan.parentID)
        XCTAssertEqual(orphan.deletedAt, Self.now)
        XCTAssertEqual(orphan.title, "Detached")
    }

    func testRunningTwiceChangesNothing() throws {
        let f = try fixture()
        _ = try KronosSchemaV2Stage.convertLegacySteps(in: f.ctx, now: Self.now)
        let again = try KronosSchemaV2Stage.convertLegacySteps(in: f.ctx, now: Self.now)
        XCTAssertEqual(again, .init(converted: 0, orphans: 0, alreadyTasks: 0))
        XCTAssertEqual(try f.ctx.fetchCount(FetchDescriptor<V1.KTask>()), 7)
    }

    func testAStepWhoseIdIsAlreadyATaskIsNotDuplicated() throws {
        let f = try fixture()
        let dup = V1.KSubtask(title: "Pack again", sortIndex: 0)
        dup.id = f.solo.id
        dup.task = f.pack
        f.ctx.insert(dup)
        try f.ctx.save()
        let result = try KronosSchemaV2Stage.convertLegacySteps(in: f.ctx, now: Self.now)
        XCTAssertEqual(result.alreadyTasks, 1)
        XCTAssertEqual(result.converted, 3)
        let soloID = f.solo.id
        XCTAssertEqual(try f.ctx.fetchCount(FetchDescriptor<V1.KTask>(predicate: #Predicate { $0.id == soloID })), 1)
        XCTAssertEqual(try task(f.ctx, soloID).title, "Solo")
        XCTAssertEqual(steps(f.ctx), 0)
    }

    func testAnEmptyStoreConvertsNothing() throws {
        let result = try KronosSchemaV2Stage.convertLegacySteps(in: ModelContext(try emptyV1()))
        XCTAssertEqual(result, .init(converted: 0, orphans: 0, alreadyTasks: 0))
    }

    func testTheAuditSnapshotReadsV1Rows() throws {
        let f = try fixture()
        let snap = try SubtaskMigrationAudit.capture(v1: f.ctx)
        XCTAssertEqual(snap.taskCount, 3)
        XCTAssertEqual(snap.steps.count, 4)
        XCTAssertEqual(Set(snap.steps.map(\.title)), ["Passport", "Charger", "Gone step", "Detached"])
        XCTAssertNil(snap.steps.first { $0.id == Self.orphanID }?.ownerID)
        XCTAssertEqual(snap.steps.first { $0.id == Self.chargerID }?.ownerID, f.pack.id)
    }

    /// The frozen V1 step keeps the defaults older builds wrote: a converted row has no due day
    /// and priority none unless it had them.
    func testFrozenV1Defaults() {
        let s = V1.KSubtask(title: "Step")
        XCTAssertNil(s.dueDay)
        XCTAssertEqual(s.priorityRaw, 0)
        XCTAssertFalse(s.isDone)
        XCTAssertEqual(s.notes, "")
        let t = V1.KTask(title: "Task")
        XCTAssertEqual(t.statusRaw, 0)
        XCTAssertEqual(t.effortRaw, 0)
        XCTAssertTrue(t.needsTriage)
        XCTAssertEqual(V1.KRule(text: "r").sourceRaw, 1)
        XCTAssertEqual(V1.KSavedView(name: "v").sortModeRaw, 1)
    }
}
