import Foundation
import Security
import SwiftData
import Testing
@testable import KronosCore

/// The CloudKit schema freeze: the main schema that will be deployed is EXACTLY this set of
/// entities, attributes and relationships, written out by hand from the planned field set. A
/// field added or removed anywhere shows up here as a difference (zero differences = the
/// reviewed schema). The device-local models never appear in it.
@Suite("SchemaFreezeTests")
struct SchemaFreezeTests {

    /// entity -> (attributes, relationships)
    static let frozen: [String: (Set<String>, Set<String>)] = [
        "KArea": (["id", "name", "colorHex", "icon", "sortIndex", "createdAt", "updatedAt"], ["projects"]),
        "KProject": (["id", "name", "colorHex", "icon", "emoji", "sortIndex", "isArchived", "createdAt", "updatedAt"],
                     ["area", "tasks"]),
        "KLabel": (["id", "name", "colorHex", "createdAt", "updatedAt"], ["tasks"]),
        "KTask": ([
            "id", "createdAt", "updatedAt", "title", "notes", "firstMove",
            "statusRaw", "priorityRaw", "depthRaw", "effortRaw", "dread", "energyKindRaw", "estimateMinutes",
            "dueDay", "originalDueDay", "completedAt", "sortIndex", "ordoIndex", "deletedAt",
            "triagedAt", "triageModel", "triageRationale", "triageFeedback", "triageReviewedAt", "needsTriage",
            "recurrenceRule", "seriesID", "calendarEventID", "waitsOnIDs", "externalID", "source",
            "plannedDay", "carryCount", "triageFilledFieldsRaw", "lockedFieldsRaw",
            "reviewRaw", "contextJSON", "resultJSON", "agentID", "assigneeRaw",
            "triageLeaseOwner", "triageLeaseUntil",
            "projectID", "areaID", "isProjectArchived", "parentID",
        ], ["project", "labels", "parent", "children", "attachments"]),
        "KRule": (["id", "text", "scopeRaw", "sourceRaw", "isActive", "createdAt", "updatedAt"], []),
        "KSavedView": (["id", "name", "icon", "sortIndex", "filterJSON", "sortModeRaw", "groupByRaw", "sortJSON",
                        "showDone", "createdAt", "updatedAt"], []),
        "KStoreMeta": (["id", "key", "value", "updatedAt"], []),
        "KSession": (["id", "taskID", "kindRaw", "plannedMinutes", "startedAt", "endedAt", "phaseJSON", "device",
                      "outcomeRaw", "flowSelfReport"], []),
        "KAttachment": (["id", "kindRaw", "title", "url", "data", "byteCount", "createdAt"], ["task"]),
    ]

    /// Every difference between the schema SwiftData builds and the frozen table.
    static func differences() -> [String] {
        let schema = Schema(versionedSchema: KronosSchemaV2.self)
        var out: [String] = []
        let built = Set(schema.entities.map(\.name))
        let planned = Set(frozen.keys)
        for e in built.subtracting(planned).sorted() { out.append("entity not in the plan: \(e)") }
        for e in planned.subtracting(built).sorted() { out.append("planned entity missing: \(e)") }
        for e in schema.entities {
            guard let (attrs, rels) = frozen[e.name] else { continue }
            let a = Set(e.attributes.map(\.name)), r = Set(e.relationships.map(\.name))
            for x in a.subtracting(attrs).sorted() { out.append("\(e.name).\(x) not in the plan") }
            for x in attrs.subtracting(a).sorted() { out.append("\(e.name).\(x) missing") }
            for x in r.subtracting(rels).sorted() { out.append("\(e.name).\(x) (relationship) not in the plan") }
            for x in rels.subtracting(r).sorted() { out.append("\(e.name).\(x) (relationship) missing") }
            for x in e.attributes where x.isUnique { out.append("\(e.name).\(x.name) is unique (CloudKit forbids)") }
            for x in e.relationships where !x.isOptional { out.append("\(e.name).\(x.name) is required (CloudKit forbids)") }
        }
        return out
    }

    @Test func mainSchemaEqualsTheFrozenTable() {
        let diff = Self.differences()
        #expect(diff.isEmpty, "\(diff)")
        print("SCHEMA DIFF V2 vs plan: \(diff.count) differences")
    }

    @Test func localModelsStayOutOfTheMainSchema() {
        let names = Set(Schema(versionedSchema: KronosSchemaV2.self).entities.map(\.name))
        #expect(!names.contains("KAgent") && !names.contains("KActivity") && !names.contains("KSubtask"))
        let local = Set(Schema(versionedSchema: KronosLocalSchemaV1.self).entities.map(\.name))
        #expect(local == ["KAgent", "KActivity"])
    }
}

/// Opening the store against the real private iCloud database needs the iCloud entitlement,
/// which a test binary without a Team ID does not have: the test is then SKIPPED (reported as
/// skipped, never as passed).
@Suite("RealCloudKitContainerTests")
struct RealCloudKitContainerTests {

    static let containerID = "iCloud.com.besic.kronos"

    /// True when this process carries an iCloud container entitlement.
    static var hasICloudEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        return value != nil
        #else
        return false
        #endif
    }

    @Test("real private container round trip",
          .enabled(if: hasICloudEntitlement, "no iCloud entitlement in this test binary: real .private container test SKIPPED"))
    @MainActor func realPrivateContainer() throws {
        let schema = Schema(versionedSchema: KronosSchemaV2.self)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-ck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("ck.store"),
                                        cloudKitDatabase: .private(Self.containerID))
        let container = try ModelContainer(for: schema, migrationPlan: KronosMigrationPlan.self, configurations: [config])
        let task = KTask(title: "CloudKit probe")
        container.mainContext.insert(task)
        try container.mainContext.save()
        #expect(try container.mainContext.fetchCount(FetchDescriptor<KTask>()) == 1)
    }

    @Test func thisBinaryHasNoEntitlement() {
        // Documents why the test above is skipped here; flips when a Team ID build runs it.
        #expect(!Self.hasICloudEntitlement)
    }
}
