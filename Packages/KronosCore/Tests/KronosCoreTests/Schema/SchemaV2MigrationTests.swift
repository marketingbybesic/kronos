import Foundation
import SwiftData
import XCTest
@testable import KronosCore

/// Opening a V1 store under schema V2: step rows become child tasks inside the migration stage,
/// the step table is gone, every other row survives, a second open changes nothing, and a failed
/// safety copy leaves the store on V1. Expectations are literal (see `SchemaV2Fixture`).
///
/// XCTest on purpose, not Swift Testing. SwiftData resolves a model's entity by NAME across the
/// whole process, so while a V1 container (or the stage's V1 context) is alive, a V2 `KTask`
/// written on another thread can be encoded against the V1 entity and abort the process.
/// `swift test` runs XCTest cases one at a time in their own process, apart from the parallel
/// Swift Testing run, which is exactly the isolation these need. The app is not exposed: the
/// stage runs inside `TaskStore.init` on the main thread before anything else touches the store
/// (proven by `testNewRowsSaveWithV2FieldsRightAfterAnUpgrade`).
final class SchemaV2MigrationTests: XCTestCase {
    typealias F = SchemaV2Fixture

    override func setUp() {
        super.setUp()
        SchemaV2Upgrade.setBlocked(false)
        _ = SchemaV2Upgrade.takeConverted()
    }

    override func tearDown() {
        SchemaV2Upgrade.setBlocked(false)
        _ = SchemaV2Upgrade.takeConverted()
        super.tearDown()
    }

    private func task(_ ctx: ModelContext, _ id: UUID) throws -> KTask {
        try XCTUnwrap(try ctx.fetch(FetchDescriptor<KTask>(predicate: #Predicate { $0.id == id })).first)
    }

    #if os(macOS) // V1 fixture rows are not readable through sqlite3 on the iOS simulator yet (count query returns nil)
    func testV1StoreWithStepsOpensAsV2WithEveryStepAsAChildTask() throws {
        let (dir, url) = try F.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try F.writeV1(to: url)
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKSUBTASK"), 5, "fixture holds 5 step rows")
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKTASK"), 4)
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: url), false)

        let before = try SubtaskMigrationAudit.capture(v1: ModelContext(try F.openV1(url)))
        XCTAssertEqual(before.taskCount, 4)
        XCTAssertEqual(before.steps.count, 5)

        let container = try F.openV2(url)
        let ctx = ModelContext(container)
        XCTAssertEqual(SchemaV2Upgrade.takeConverted(), .init(converted: 4, orphans: 1, alreadyTasks: 0))

        let tasks = try ctx.fetch(FetchDescriptor<KTask>())
        XCTAssertEqual(tasks.count, 9, "4 tasks + 5 steps")
        let pack = try task(ctx, F.packID)
        XCTAssertEqual(pack.orderedChildren.map(\.title), ["Sub", "Charger", "Passport", "Inner"])
        XCTAssertEqual(pack.orderedChildren.map(\.id), [F.subID, F.chargerID, F.passportID, F.innerID])
        XCTAssertEqual((pack.labels ?? []).map(\.name), ["Errand"])

        let charger = try task(ctx, F.chargerID)
        XCTAssertEqual(charger.parentID, F.packID)
        XCTAssertEqual(charger.parent?.id, F.packID)
        XCTAssertEqual(charger.statusRaw, 0)
        XCTAssertNil(charger.completedAt)
        XCTAssertEqual(charger.dueDay.map(Day.iso), "2026-10-10")
        XCTAssertEqual(charger.originalDueDay.map(Day.iso), "2026-10-10")
        XCTAssertEqual(charger.priorityRaw, 3)
        XCTAssertEqual(charger.notes, "link://web|Shop|https://example.com")
        XCTAssertEqual(charger.sortIndex, 1024)
        XCTAssertEqual(charger.projectID, F.projectID)
        XCTAssertEqual(charger.project?.id, F.projectID)
        XCTAssertEqual(charger.areaID, F.areaID)
        XCTAssertEqual(charger.createdAt, F.t0)
        XCTAssertEqual(charger.updatedAt, F.t1)
        XCTAssertFalse(charger.needsTriage)
        XCTAssertNil(charger.deletedAt)

        let passport = try task(ctx, F.passportID)
        XCTAssertEqual(passport.statusRaw, 4)
        XCTAssertEqual(passport.completedAt, F.t1)

        XCTAssertEqual(try task(ctx, F.innerID).parentID, F.packID, "a step of a child lands under the top-level task")

        let gone = try task(ctx, F.goneID)
        XCTAssertEqual(gone.parentID, F.oldID)
        XCTAssertEqual(gone.deletedAt, F.t0, "a deleted task's step is deleted with the same stamp")

        let detached = try task(ctx, F.detachedID)
        XCTAssertNil(detached.parentID)
        XCTAssertNil(detached.projectID)
        XCTAssertNotNil(detached.deletedAt)

        // V2 columns arrive with their defaults on every migrated row.
        for t in tasks {
            XCTAssertNil(t.plannedDay); XCTAssertEqual(t.carryCount, 0)
            XCTAssertEqual(t.lockedFieldsRaw, ""); XCTAssertEqual(t.triageFilledFieldsRaw, "")
            XCTAssertEqual(t.reviewRaw, 0); XCTAssertEqual(t.assigneeRaw, 0)
            XCTAssertNil(t.agentID); XCTAssertNil(t.contextJSON); XCTAssertNil(t.resultJSON)
            XCTAssertNil(t.triageLeaseOwner); XCTAssertNil(t.triageLeaseUntil)
            XCTAssertEqual((t.attachments ?? []).count, 0)
        }
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KArea>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KProject>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KLabel>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KRule>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KSavedView>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KStoreMeta>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KSession>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KAttachment>()), 0)

        XCTAssertEqual(SubtaskMigrationAudit.verify(before, in: ctx), [])
        XCTAssertFalse(F.tableExists(url, "ZKSUBTASK"), "the step table is dropped")
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKTASK"), 9)
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: url), true)
    }

    #endif
    /// The stage loads the V1 classes inside the open. New V2 rows written right after it (the
    /// app's first edits) must still carry every V2 field and save.
    @MainActor
    func testNewRowsSaveWithV2FieldsRightAfterAnUpgrade() throws {
        let (dir, url) = try F.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try F.writeV1(to: url)
        let container = try F.openV2(url)
        XCTAssertNotNil(SchemaV2Upgrade.takeConverted(), "the stage ran")
        let ctx = ModelContext(container)
        let t = KTask(title: "After upgrade")
        t.plannedDay = 20_000
        t.carryCount = 2
        t.lockedFieldsRaw = "priority"
        t.reviewRaw = 1
        ctx.insert(t)
        let link = KAttachment(kindRaw: 0, title: "Spec", url: "https://example.com/spec")
        ctx.insert(link)
        link.task = t
        ctx.insert(KStoreMeta(key: "schema", value: "2"))
        ctx.insert(KSession(taskID: t.id, kindRaw: 0, plannedMinutes: 25))
        try ctx.save()

        let fresh = ModelContext(container)
        let got = try task(fresh, t.id)
        XCTAssertEqual(got.plannedDay, 20_000)
        XCTAssertEqual(got.carryCount, 2)
        XCTAssertEqual(got.lockedFieldsRaw, "priority")
        XCTAssertEqual(got.reviewRaw, 1)
        XCTAssertEqual((got.attachments ?? []).map(\.title), ["Spec"])
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<KStoreMeta>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<KSession>()), 1)

        // And the app's store path still works after the V1 classes were loaded.
        let store = try TaskStore(inMemory: true)
        let made = store.createNoUndo(title: "Fresh")
        store.updateNoUndo(made.id) { $0.plannedDay = 20_001 }
        XCTAssertEqual(store.task(made.id)?.plannedDay, 20_001)
    }

    func testReopeningAV2StoreChangesNothing() throws {
        let (dir, url) = try F.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try F.writeV1(to: url)
        let first = try F.dump(ModelContext(try F.openV2(url)))
        XCTAssertEqual(first.count, 9)
        XCTAssertNotNil(SchemaV2Upgrade.takeConverted())

        let second = try F.dump(ModelContext(try F.openV2(url)))
        XCTAssertEqual(second, first)
        XCTAssertNil(SchemaV2Upgrade.takeConverted(), "the stage does not run on a V2 store")
    }

    func testAFailedSafetyCopyLeavesTheStoreOnV1() throws {
        let (dir, url) = try F.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try F.writeV1(to: url)

        SchemaV2Upgrade.setBlocked(true)
        XCTAssertThrowsError(try F.openV2(url), "opening throws instead of upgrading without a copy")
        XCTAssertNil(SchemaV2Upgrade.takeConverted())
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: url), false)
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKSUBTASK"), 5, "step rows untouched")
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKTASK"), 4)

        // The next launch, with a good copy, upgrades it.
        SchemaV2Upgrade.setBlocked(false)
        XCTAssertEqual(try ModelContext(try F.openV2(url)).fetchCount(FetchDescriptor<KTask>()), 9)
    }

    func testVersionProbeReadsTheStoreMetadata() throws {
        let (dir, url) = try F.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(SchemaV2Upgrade.storeIsV2(at: url), "no file")
        try Data("not a store".utf8).write(to: url)
        XCTAssertNil(SchemaV2Upgrade.storeIsV2(at: url), "not a store")
        try FileManager.default.removeItem(at: url)

        let fresh = dir.appendingPathComponent("fresh.store")
        _ = try F.openV2(fresh)
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: fresh), true, "a store created by V2")
        try F.writeV1(to: url)
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: url), false, "a store written by V1")
    }

    // MARK: the pre-V2 safety copy, on real store files

    func testAV1StoreIsCopiedIntoPreV2BeforeItOpens() throws {
        let fm = FileManager.default
        let (dir, url) = try F.folder()
        defer { try? fm.removeItem(at: dir) }
        try F.writeV1(to: url)
        let result = SubtaskToTaskMigration.backupBeforeV2(store: url, container: dir, now: F.t0)
        guard case .made(let folder) = result else { return XCTFail("expected a copy, got \(result)") }
        XCTAssertFalse(SchemaV2Upgrade.isBlocked)
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, "Backups")
        XCTAssertEqual(folder.lastPathComponent, "pre-v2-2026-09-21T141320Z")
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: folder.path).contains("Kronos.store"))
        let copy = folder.appendingPathComponent("Kronos.store")
        XCTAssertEqual(F.sqliteInt(copy, "SELECT count(*) FROM ZKSUBTASK"), 5, "the copy is the V1 data")
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: copy), false)
    }

    func testAV2StoreOrNoStoreTakesNoCopy() throws {
        let fm = FileManager.default
        let (dir, url) = try F.folder()
        defer { try? fm.removeItem(at: dir) }
        XCTAssertEqual(SubtaskToTaskMigration.backupBeforeV2(store: url, container: dir, now: F.t0), .notNeeded)
        _ = try F.openV2(url)
        XCTAssertEqual(SubtaskToTaskMigration.backupBeforeV2(store: url, container: dir, now: F.t0), .notNeeded)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("Backups").path))
        XCTAssertFalse(SchemaV2Upgrade.isBlocked)
    }

    func testAFailedCopyBlocksTheUpgradeAndQueuesTheNotice() throws {
        let fm = FileManager.default
        let (dir, url) = try F.folder()
        defer { try? fm.removeItem(at: dir) }
        try F.writeV1(to: url)
        let result = SubtaskToTaskMigration.backupBeforeV2(store: url, container: dir, now: F.t0, ops: FailingCopy())
        guard case .failed = result else { return XCTFail("expected failure, got \(result)") }
        XCTAssertTrue(SchemaV2Upgrade.isBlocked)
        XCTAssertNotNil(SubtaskToTaskMigration.takePendingNotice(container: dir))
        let leftovers = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path)) ?? []
        XCTAssertEqual(leftovers, [], "the partial folder is removed")
        XCTAssertThrowsError(try F.openV2(url))
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: url), false)
    }

    // MARK: stores older than V1 (written before child tasks existed)

    func testAStoreOlderThanV1IsRefusedByThePlanAlone() throws {
        let (dir, url) = try F.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SchemaV0Test.write(to: url)
        XCTAssertTrue(SchemaV0Test.matches(url))
        XCTAssertEqual(SchemaV2Upgrade.storeIsV1(at: url), false)
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: url), false)
        XCTAssertThrowsError(try F.openV2(url), "SwiftData stages only from a version the plan knows")
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKSUBTASK"), 4, "and changes nothing")
        XCTAssertTrue(SchemaV0Test.matches(url))
    }

    func testAStoreOlderThanV1IsCopiedBroughtToV1AndThenUpgraded() throws {
        let fm = FileManager.default
        let (dir, url) = try F.folder()
        defer { try? fm.removeItem(at: dir) }
        try SchemaV0Test.write(to: url)

        let result = SubtaskToTaskMigration.backupBeforeV2(store: url, container: dir, now: F.t0)
        guard case .made(let folder) = result else { return XCTFail("expected a copy, got \(result)") }
        XCTAssertTrue(SchemaV0Test.matches(folder.appendingPathComponent("Kronos.store")), "the copy is the original shape")
        XCTAssertEqual(SchemaV2Upgrade.storeIsV1(at: url), true, "the store itself is now V1")
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKSUBTASK"), 4, "steps still there for the stage")
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKTASK"), 3)

        let ctx = ModelContext(try F.openV2(url))
        XCTAssertEqual(SchemaV2Upgrade.takeConverted(), .init(converted: 3, orphans: 1, alreadyTasks: 0))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<KTask>()), 7)
        let pack = try task(ctx, F.packID)
        XCTAssertEqual(pack.orderedChildren.map(\.title), ["Charger", "Passport"])
        XCTAssertEqual(try task(ctx, F.chargerID).priorityRaw, 3)
        XCTAssertEqual(try task(ctx, F.passportID).statusRaw, 4)
        XCTAssertEqual(try task(ctx, F.goneID).deletedAt, F.t0)
        XCTAssertFalse(F.tableExists(url, "ZKSUBTASK"))
        XCTAssertEqual(SchemaV2Upgrade.storeIsV2(at: url), true)

        // The V1 container used to bring the store up is gone: new V2 rows save normally.
        let made = KTask(title: "Written after the upgrade")
        made.plannedDay = 20_002
        made.lockedFieldsRaw = "due"
        ctx.insert(made)
        try ctx.save()
        XCTAssertEqual(try task(ModelContext(try F.openV2(url)), made.id).plannedDay, 20_002)
    }

    func testBringingToV1LeavesV1V2AndNonStoresAlone() throws {
        let (dir, url) = try F.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try F.writeV1(to: url)
        XCTAssertEqual(SchemaV2Upgrade.bringOlderStoreToV1(at: url), .notNeeded)
        XCTAssertEqual(F.sqliteInt(url, "SELECT count(*) FROM ZKSUBTASK"), 5)
        let v2 = dir.appendingPathComponent("v2.store")
        _ = try F.openV2(v2)
        XCTAssertEqual(SchemaV2Upgrade.bringOlderStoreToV1(at: v2), .notNeeded)
        let junk = dir.appendingPathComponent("junk.store")
        try Data("not a store".utf8).write(to: junk)
        XCTAssertEqual(SchemaV2Upgrade.bringOlderStoreToV1(at: junk), .notNeeded)
        XCTAssertEqual(try String(contentsOf: junk, encoding: .utf8), "not a store")
    }

    // MARK: the launch entry point after the open

    @MainActor
    func testRunIfNeededWritesTheMarkerOnceReportsTheStageAndKeepsTheCopy() throws {
        let fm = FileManager.default
        let (dir, url) = try F.folder()
        defer { try? fm.removeItem(at: dir) }
        try F.writeV1(to: url)
        let backup = SubtaskToTaskMigration.backupBeforeV2(store: url, container: dir, now: F.t0)
        guard case .made(let folder) = backup else { return XCTFail("expected a copy, got \(backup)") }
        let marker = dir.appendingPathComponent("migrations/subtasksToTasks.v1")
        let store = try TaskStore(inMemory: true)

        // A failed copy writes no marker, so the next launch retries.
        XCTAssertNil(SubtaskToTaskMigration.runIfNeeded(store: store, backup: .failed(reason: "disk full"), marker: marker))
        XCTAssertFalse(fm.fileExists(atPath: marker.path))

        _ = try F.openV2(url)
        XCTAssertEqual(SubtaskToTaskMigration.runIfNeeded(store: store, backup: backup, marker: marker),
                       .init(converted: 4, orphans: 1, alreadyTasks: 0))
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("Kronos.store").path), "the pre-V2 copy stays")

        _ = try F.openV2(url)
        XCTAssertNil(SubtaskToTaskMigration.runIfNeeded(store: store, backup: .notNeeded, marker: marker))
    }

    @MainActor
    func testAFreshStoreGetsTheMarkerWithNothingConverted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("migrations/subtasksToTasks.v1")
        let store = try TaskStore(inMemory: true)
        XCTAssertEqual(SubtaskToTaskMigration.runIfNeeded(store: store, backup: .notNeeded, marker: marker),
                       .init(converted: 0, orphans: 0, alreadyTasks: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Positive control for the audit the copy check relies on.
    func testAuditFailsOnADroppedRowAndAChangedTitle() throws {
        let (dir, url) = try F.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try F.writeV1(to: url)
        let before = try SubtaskMigrationAudit.capture(v1: ModelContext(try F.openV1(url)))
        let container = try F.openV2(url)
        let ctx = ModelContext(container)
        XCTAssertEqual(SubtaskMigrationAudit.verify(before, in: ctx), [])

        let charger = try task(ctx, F.chargerID)
        charger.title = "Charger (edited)"
        XCTAssertTrue(SubtaskMigrationAudit.verify(before, in: ctx).contains("title checksum differs"))
        charger.title = "Charger"

        ctx.delete(try task(ctx, F.passportID))
        try ctx.save()
        let problems = SubtaskMigrationAudit.verify(before, in: ctx)
        XCTAssertTrue(problems.contains("missing \(F.passportID)"))
        XCTAssertTrue(problems.contains("tasks after 8 != 9"))
    }

    /// Every copy throws, the way a full disk does.
    private struct FailingCopy: MigrationFileOps {
        private let real = DefaultMigrationFileOps()
        func exists(_ url: URL) -> Bool { real.exists(url) }
        func createDirectory(_ url: URL) throws { try real.createDirectory(url) }
        func copy(_ from: URL, _ to: URL) throws { throw CocoaError(.fileWriteOutOfSpace) }
        func size(_ url: URL) throws -> Int { try real.size(url) }
        func remove(_ url: URL) throws { try real.remove(url) }
        func write(_ url: URL, _ data: Data) { real.write(url, data) }
    }
}
