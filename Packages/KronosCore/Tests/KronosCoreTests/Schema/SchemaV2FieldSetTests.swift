import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// Schema V2 carries every planned field, so no further version is needed before a CloudKit
/// deploy. The tables below are the planned field set written out by hand; each row is checked
/// against the schema SwiftData builds (name, optional or not, and for scalars the default).
@Suite("SchemaV2FieldSetTests")
struct SchemaV2FieldSetTests {

    /// (attribute, optional)
    static let newTaskAttributes: [(String, Bool)] = [
        ("plannedDay", true), ("carryCount", false), ("triageFilledFieldsRaw", false),
        ("lockedFieldsRaw", false), ("reviewRaw", false), ("contextJSON", true), ("resultJSON", true),
        ("agentID", true), ("assigneeRaw", false), ("triageLeaseOwner", true), ("triageLeaseUntil", true),
    ]
    static let reusedTaskAttributes = ["originalDueDay", "source", "externalID", "triageModel"]

    static let models: [String: [(String, Bool)]] = [
        "KStoreMeta": [("id", false), ("key", false), ("value", false), ("updatedAt", false)],
        "KSession": [("id", false), ("taskID", true), ("kindRaw", false), ("plannedMinutes", false),
                     ("startedAt", false), ("endedAt", true), ("phaseJSON", false), ("device", false),
                     ("outcomeRaw", false), ("flowSelfReport", true)],
        "KAttachment": [("id", false), ("kindRaw", false), ("title", false), ("url", true), ("data", true),
                        ("byteCount", false), ("createdAt", false)],
    ]
    static let localModels: [String: [String]] = [
        "KAgent": ["id", "slug", "displayName", "glyph", "tokenHash", "scopesRaw", "listProjectID", "webhookURL",
                   "webhookSecretName", "rateLimitPerMinute", "dailyCreateCap", "maxPendingProposals",
                   "isEnabled", "createdAt", "lastSeenAt"],
        "KActivity": ["id", "seq", "at", "actor", "verb", "taskID", "agentID", "payloadJSON",
                      "webhookStateRaw", "webhookAttempts"],
    ]

    private func entity(_ schema: Schema, _ name: String) throws -> Schema.Entity {
        try #require(schema.entities.first { $0.name == name })
    }

    @Test func taskCarriesEveryNewField() throws {
        let task = try entity(Schema(versionedSchema: KronosSchemaV2.self), "KTask")
        let attrs = Dictionary(uniqueKeysWithValues: task.attributes.map { ($0.name, $0) })
        for (name, optional) in Self.newTaskAttributes {
            let a = try #require(attrs[name], "KTask.\(name) missing")
            #expect(a.isOptional == optional, "KTask.\(name) optional should be \(optional)")
        }
        for name in Self.reusedTaskAttributes { #expect(attrs[name] != nil, "KTask.\(name) is reused, not renamed") }
        #expect(attrs["originalDueDate"] == nil, "no second original-due field")
        #expect(task.relationships.contains { $0.name == "attachments" })
        #expect(!task.relationships.contains { $0.name == "subtasks" })
    }

    @Test func newScalarFieldsDefaultAsPlanned() {
        let t = KTask(title: "x")
        #expect(t.plannedDay == nil)
        #expect(t.carryCount == 0)
        #expect(t.triageFilledFieldsRaw == "")
        #expect(t.lockedFieldsRaw == "")
        #expect(t.reviewRaw == 0)
        #expect(t.contextJSON == nil && t.resultJSON == nil)
        #expect(t.agentID == nil)
        #expect(t.assigneeRaw == 0)
        #expect(t.triageLeaseOwner == nil && t.triageLeaseUntil == nil)
        #expect((t.attachments ?? []).isEmpty)
        let s = KSession()
        #expect(s.kindRaw == 0 && s.plannedMinutes == 0 && s.outcomeRaw == 0 && s.phaseJSON == "" && s.device == "")
        #expect(s.endedAt == nil && s.flowSelfReport == nil && s.taskID == nil)
        let a = KAttachment()
        #expect(a.kindRaw == 0 && a.title == "" && a.url == nil && a.data == nil && a.byteCount == 0)
        let m = KStoreMeta(key: "k", value: "v")
        #expect(m.key == "k" && m.value == "v")
    }

    @Test func newMainModelsHaveTheirFields() throws {
        let schema = Schema(versionedSchema: KronosSchemaV2.self)
        for (model, fields) in Self.models {
            let e = try entity(schema, model)
            let attrs = Dictionary(uniqueKeysWithValues: e.attributes.map { ($0.name, $0) })
            for (name, optional) in fields {
                let a = try #require(attrs[name], "\(model).\(name) missing")
                #expect(a.isOptional == optional, "\(model).\(name) optional should be \(optional)")
            }
        }
        let attachment = try entity(schema, "KAttachment")
        #expect(attachment.relationships.map(\.name) == ["task"])
        let data = try #require(attachment.attributes.first { $0.name == "data" })
        #expect(data.options.contains(.externalStorage), "attachment bytes live outside the SQLite file")
    }

    @Test func localModelsHaveTheirFieldsAndNoRelationships() throws {
        let schema = Schema(versionedSchema: KronosLocalSchemaV1.self)
        for (model, fields) in Self.localModels {
            let e = try entity(schema, model)
            #expect(Set(e.attributes.map(\.name)) == Set(fields), "\(model) fields")
            #expect(e.relationships.isEmpty)
        }
    }
}
