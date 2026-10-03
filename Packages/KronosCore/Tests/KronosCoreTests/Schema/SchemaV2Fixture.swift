import Foundation
import SQLite3
import SwiftData
@testable import KronosCore

/// A V1 store on disk, written through the frozen V1 schema, holding step rows the V1 -> V2
/// stage must convert. Every id, title and date is fixed so the suites can state their
/// expectations literally.
///
///   Life (area) > Home (project)
///   Pack   [Home, label Errand]        steps: Charger (open, due 2026-10-10, high), Passport (done)
///     Sub  [child of Pack, sort 512]   step:  Inner (owned by a child: lands under Pack)
///   Old    [Home, deleted at t0]       step:  Gone step
///   Solo   [no project]
///   (no task)                          step:  Detached
enum SchemaV2Fixture {
    static let areaID     = UUID(uuidString: "B0000000-0000-0000-0000-00000000000A")!
    static let projectID  = UUID(uuidString: "B0000000-0000-0000-0000-00000000000B")!
    static let packID     = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
    static let oldID      = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
    static let soloID     = UUID(uuidString: "B0000000-0000-0000-0000-000000000003")!
    static let subID      = UUID(uuidString: "B0000000-0000-0000-0000-000000000004")!
    static let chargerID  = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
    static let passportID = UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!
    static let goneID     = UUID(uuidString: "C0000000-0000-0000-0000-000000000003")!
    static let detachedID = UUID(uuidString: "C0000000-0000-0000-0000-000000000004")!
    static let innerID    = UUID(uuidString: "C0000000-0000-0000-0000-000000000005")!
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_790_003_600)

    /// A fresh temp folder holding nothing yet; `store` is where Kronos.store goes.
    static func folder() throws -> (dir: URL, store: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-schema-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("Kronos.store"))
    }

    /// Writes the fixture as a V1 store at `url` and closes it.
    static func writeV1(to url: URL) throws {
        typealias V1 = KronosSchemaV1
        let schema = Schema(versionedSchema: V1.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = ModelContext(container)

        let area = V1.KArea(name: "Life")
        area.id = areaID
        ctx.insert(area)
        let home = V1.KProject(name: "Home", area: area)
        home.id = projectID
        ctx.insert(home)
        let errand = V1.KLabel(name: "Errand")
        ctx.insert(errand)
        let rule = V1.KRule(text: "No calls before ten")
        ctx.insert(rule)
        let view = V1.KSavedView(name: "Errands")
        ctx.insert(view)

        func task(_ id: UUID, _ title: String, _ project: V1.KProject?, sort: Double) -> V1.KTask {
            let t = V1.KTask(title: title, project: project)
            t.id = id
            t.sortIndex = sort
            t.createdAt = t0
            t.updatedAt = t0
            ctx.insert(t)
            return t
        }
        let pack = task(packID, "Pack", home, sort: 1024)
        pack.labels = [errand]
        let old = task(oldID, "Old", home, sort: 2048)
        old.deletedAt = t0
        _ = task(soloID, "Solo", nil, sort: 3072)
        let sub = task(subID, "Sub", home, sort: 512)
        sub.parent = pack
        sub.parentID = pack.id

        func step(_ id: UUID, _ title: String, _ owner: V1.KTask?, sort: Double) -> V1.KSubtask {
            let s = V1.KSubtask(title: title, sortIndex: sort)
            s.id = id
            s.createdAt = t0
            s.updatedAt = t1
            s.task = owner
            ctx.insert(s)
            return s
        }
        let charger = step(chargerID, "Charger", pack, sort: 1024)
        charger.dueDay = Day.parseISO("2026-10-10")
        charger.priorityRaw = 3
        charger.notes = "link://web|Shop|https://example.com"
        let passport = step(passportID, "Passport", pack, sort: 2048)
        passport.isDone = true
        _ = step(goneID, "Gone step", old, sort: 0)
        _ = step(detachedID, "Detached", nil, sort: 0)
        _ = step(innerID, "Inner", sub, sort: 4096)
        try ctx.save()
    }

    /// Opens `url` exactly the way `TaskStore` does: schema V2 plus the migration plan.
    static func openV2(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: KronosSchemaV2.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: KronosMigrationPlan.self, configurations: [config])
    }

    /// Opens `url` as V1 without a plan (only valid while the file is still V1).
    static func openV1(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: KronosSchemaV1.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Every task as one text line carrying the fields the conversion sets, sorted.
    static func dump(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<KTask>()).map { t in
            "\(t.id) \(t.title) status=\(t.statusRaw) prio=\(t.priorityRaw) due=\(String(describing: t.dueDay)) "
                + "sort=\(t.sortIndex) parent=\(String(describing: t.parentID)) proj=\(String(describing: t.projectID)) "
                + "deleted=\(String(describing: t.deletedAt?.timeIntervalSince1970)) "
                + "completed=\(String(describing: t.completedAt?.timeIntervalSince1970)) notes=\(t.notes) "
                + "labels=\((t.labels ?? []).map(\.name).sorted())"
        }.sorted()
    }

    /// Reads one integer with the SQLite C API, independent of SwiftData and of the code under
    /// test. Returns nil when the statement fails (for example, a table that does not exist).
    static func sqliteInt(_ url: URL, _ sql: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func tableExists(_ url: URL, _ table: String) -> Bool {
        (sqliteInt(url, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='\(table)'") ?? 0) == 1
    }
}
