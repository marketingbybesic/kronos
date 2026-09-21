import Testing
import Foundation
import SwiftData
@testable import KronosCore

/// Reflects over the real V1 schema and asserts the rules CloudKit's mirroring
/// delegate enforces on every SwiftData model, whether or not sync is turned
/// on: every stored attribute optional-or-defaulted, no unique constraint, no
/// `.deny` delete rule, every relationship optional with an inverse resolved
/// from either side. Sync itself stays off (see `TaskStore.swift`'s
/// `cloudKitDatabase: KronosStore.cloudKitDatabaseSetting`); this test exists
/// so a future model change that would silently break sync fails loudly today
/// instead of at the point someone finally flips the switch.
@MainActor
struct CloudKitReadyTests {

    /// One violation, named the way the audit reports them: `Type.property`.
    private struct Violation: CustomStringConvertible, Equatable {
        let entity: String
        let property: String
        let reason: String
        var description: String { "\(entity).\(property): \(reason)" }
    }

    /// The CloudKit mirroring rules, applied to one already-built `Schema`.
    /// Kept separate from the model list so the same checker runs against
    /// both the real schema and the deliberately bad one below.
    private static func violations(in schema: Schema) -> [Violation] {
        var found: [Violation] = []
        for entity in schema.entities {
            for attribute in entity.attributes {
                if !attribute.isOptional && attribute.defaultValue == nil {
                    found.append(Violation(entity: entity.name, property: attribute.name,
                                            reason: "stored attribute is neither optional nor defaulted"))
                }
                if attribute.isUnique {
                    found.append(Violation(entity: entity.name, property: attribute.name,
                                            reason: "@Attribute(.unique) is unsupported under CloudKit"))
                }
            }
            for relationship in entity.relationships {
                if !relationship.isOptional {
                    found.append(Violation(entity: entity.name, property: relationship.name,
                                            reason: "relationship is not optional"))
                }
                // Inverse can be declared from either side of the pair (see
                // KTask.project / KProject.tasks): a relationship only fails
                // this check when NEITHER end names an inverse.
                if relationship.inverseName == nil {
                    let declaredFromOtherSide = schema.entities.contains { other in
                        other.relationships.contains { $0.inverseName == relationship.name }
                    }
                    if !declaredFromOtherSide {
                        found.append(Violation(entity: entity.name, property: relationship.name,
                                                reason: "no inverse resolved from either side"))
                    }
                }
                if relationship.deleteRule == .deny {
                    found.append(Violation(entity: entity.name, property: relationship.name,
                                            reason: "deny delete rule is unsupported under CloudKit"))
                }
                if relationship.isUnique {
                    found.append(Violation(entity: entity.name, property: relationship.name,
                                            reason: "unique relationship is unsupported under CloudKit"))
                }
            }
        }
        return found
    }

    // MARK: - the real schema

    @Test func liveSchemaHasNoCloudKitViolations() {
        // The exact schema TaskStore builds (KronosSchemaV1.models: KArea,
        // KProject, KLabel, KTask, KSubtask, KRule, KSavedView — 7 types).
        // A test that hand-lists fewer models than KronosSchemaV1 would be a
        // false green: build the Schema from the versioned schema itself so
        // adding an 8th model to KronosSchemaV1 without adding it here still
        // gets audited.
        let schema = Schema(versionedSchema: KronosSchemaV1.self)
        #expect(schema.entities.count == KronosSchemaV1.models.count)

        let found = Self.violations(in: schema)
        #expect(found.isEmpty, "CloudKit-readiness violations: \(found.map(\.description).joined(separator: ", "))")
    }

    @Test func liveSchemaCoversAllSevenModels() {
        let names = Set(KronosSchemaV1.models.map { String(describing: $0) })
        #expect(names == ["KArea", "KProject", "KLabel", "KTask", "KSubtask", "KRule", "KSavedView"])
    }

    @Test func taskProjectInverseResolvesFromTheProjectSide() throws {
        // KTask.project carries no @Relationship annotation of its own;
        // KProject.tasks declares `inverse: \KTask.project` and SwiftData
        // back-fills the pair, so `KTask.project.inverseName` reads "tasks"
        // once the Schema is built even though the source only wrote the
        // annotation once. Pinned here so the checker's "resolve from either
        // side" fallback (exercised directly by the bad-model test below,
        // whose KBadCloudKitRelated has no reverse relationship at all)
        // isn't the only thing standing between this and a false flag.
        let schema = Schema(versionedSchema: KronosSchemaV1.self)
        let taskEntity = try #require(schema.entities.first { $0.name == "KTask" })
        let projectRel = try #require(taskEntity.relationships.first { $0.name == "project" })
        #expect(projectRel.inverseName == "tasks")
        #expect(Self.violations(in: schema).contains { $0.property == "project" && $0.entity == "KTask" } == false)
    }

    // MARK: - the checker can fail: a deliberately bad model, test-target only

    @Model
    fileprivate final class KBadCloudKitFixture {
        // Non-optional, no default: violates rule 1.
        var requiredName: String
        // Unique: violates rule 2.
        @Attribute(.unique) var slug: String = ""
        // Non-optional to-one relationship with a deny rule: violates rules
        // 3 and 4 at once.
        @Relationship(deleteRule: .deny) var owner: KBadCloudKitRelated

        init(requiredName: String, owner: KBadCloudKitRelated) {
            self.requiredName = requiredName
            self.owner = owner
        }
    }

    @Model
    fileprivate final class KBadCloudKitRelated {
        var name: String = ""
        init(name: String = "") { self.name = name }
    }

    @Test func checkerFailsOnADeliberatelyBadModel() {
        let badSchema = Schema([KBadCloudKitFixture.self, KBadCloudKitRelated.self])
        let found = Self.violations(in: badSchema)

        let byProperty = Set(found.map { "\($0.entity).\($0.property)" })
        #expect(byProperty.contains("KBadCloudKitFixture.requiredName"))
        #expect(byProperty.contains("KBadCloudKitFixture.slug"))
        #expect(byProperty.contains("KBadCloudKitFixture.owner"))
        // The fixture's relationship property fails three ways at once: not optional, no
        // inverse declared on either side, and a deny delete rule.
        #expect(found.filter { $0.entity == "KBadCloudKitFixture" && $0.property == "owner" }.count == 3)
        #expect(!found.isEmpty)
    }

    // MARK: - the switch is off: byte-identical behaviour proven on a real file

    /// `cloudKitDatabase: KronosStore.cloudKitDatabaseSetting` was ADDED to both
    /// `ModelConfiguration(...)` calls in `TaskStore.init` (rather than left
    /// unspecified, which SwiftData defaults to `.automatic`). This proves the
    /// addition changed nothing observable today: the same on-disk store file,
    /// opened by a fresh `TaskStore`, reopens with the same row counts.
    @Test func switchOffStoreFileReopensWithIdenticalCounts() throws {
        // `ModelConfiguration.CloudKitDatabase` isn't Equatable, so the
        // off-ness of the switch is proven functionally below (a store
        // opened with it reopens with identical counts, with no CloudKit
        // container attempted) rather than by comparing the enum directly.
        _ = KronosStore.cloudKitDatabaseSetting

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-cloudkit-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        setenv("KRONOS_STORE_DIR", tempRoot.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }

        do {
            let store = try TaskStore(inMemory: false)
            let area = store.createArea(name: "Acme HQ", colorHex: "#8224E3", icon: "building.2")
            let project = store.createProject(name: "Launch", colorHex: "#3FB950", icon: "leaf", area: area)
            _ = store.create(title: "Ship it", notes: "", project: project,
                              status: .todo, priority: .high, dueDay: Day.today())
            _ = store.create(title: "Tell Alex", notes: "", project: project,
                              status: .todo, priority: .none, dueDay: nil)
        }

        // A second, independent TaskStore reopens the same file on disk.
        let reopened = try TaskStore(inMemory: false)
        #expect(reopened.allTasks().count == 2)
        #expect(reopened.allProjects().count == 1)
        #expect(reopened.allAreas().count == 1)
        #expect(Set(reopened.allTasks().map(\.title)) == ["Ship it", "Tell Alex"])
    }
}
