import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// A JSON backup keeps every schema V2 task field (planning, provenance, locks, review and agent fields,
/// attachments): export, import into an empty store, same values. A file written before these
/// fields existed still imports, with the defaults. Values set by hand.
@MainActor
@Suite("V2FieldsExportImportTests")
struct V2FieldsExportImportTests {

    static let agent = UUID(uuidString: "0A0A0A0A-0000-0000-0000-000000000001")!
    static let fileID = UUID(uuidString: "0A0A0A0A-0000-0000-0000-000000000002")!
    static let created = Date(timeIntervalSince1970: 1_700_000_123.5)

    private func filled() throws -> (TaskStore, UUID) {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Agent task")
        s.updateNoUndo(t.id) {
            $0.triageFilledFieldsRaw = "priority,effort"
            $0.lockedFieldsRaw = "due"
            $0.reviewRaw = 1
            $0.contextJSON = #"{"why":"asked by the owner"}"#
            $0.resultJSON = #"{"done":true}"#
            $0.agentID = Self.agent
            $0.plannedDay = 20_400
            $0.carryCount = 3
            $0.assigneeRaw = 1
        }
        let file = KAttachment(kindRaw: 1, title: "Brief.pdf", url: "file:///Brief.pdf")
        file.id = Self.fileID
        file.data = Data([0x25, 0x50, 0x44, 0x46])
        file.byteCount = 4
        file.createdAt = Self.created
        file.task = s.task(t.id)
        s.context.insert(file)
        try s.context.save()
        return (s, t.id)
    }

    @Test func everyV2FieldSurvivesARoundTrip() throws {
        let (s, id) = try filled()
        let data = JSONExporter(store: s).exportData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"lockedFields\" : \"due\""))
        #expect(text.contains("\"review\" : 1"))

        let fresh = try TaskStore(inMemory: true)
        _ = try KronosImporter(store: fresh).importData(data, mode: .merge)
        let t = try #require(fresh.task(id))
        #expect(t.triageFilledFieldsRaw == "priority,effort")
        #expect(t.lockedFieldsRaw == "due")
        #expect(t.reviewRaw == 1)
        #expect(t.contextJSON == #"{"why":"asked by the owner"}"#)
        #expect(t.resultJSON == #"{"done":true}"#)
        #expect(t.agentID == Self.agent)
        #expect(t.assigneeRaw == 1)
        #expect(t.plannedDay == 20_400)
        #expect(t.carryCount == 3)
        let files = t.attachments ?? []
        #expect(files.count == 1)
        let f = try #require(files.first)
        #expect(f.id == Self.fileID && f.kindRaw == 1 && f.title == "Brief.pdf" && f.url == "file:///Brief.pdf")
        #expect(f.data == Data([0x25, 0x50, 0x44, 0x46]) && f.byteCount == 4)
        #expect(f.createdAt == Self.created)

        // Importing the same file again adds no second attachment.
        _ = try KronosImporter(store: fresh).importData(data, mode: .merge)
        #expect(try fresh.context.fetchCount(FetchDescriptor<KAttachment>()) == 1)
    }

    /// A task that never used the V2 fields writes none of their keys (old readers and hash
    /// checks see the same file as before).
    @Test func defaultsWriteNoKeys() throws {
        let s = try TaskStore(inMemory: true)
        _ = s.create(title: "Plain")
        let text = String(decoding: JSONExporter(store: s).exportData(), as: UTF8.self)
        for key in ["triageFilledFields", "lockedFields", "\"review\"", "contextJSON", "resultJSON",
                    "agentID", "\"assignee\"", "attachments"] {
            #expect(!text.contains(key), "\(key)")
        }
    }

    /// A file from before these fields: every V2 field takes its default.
    @Test func olderFileImportsWithDefaults() throws {
        let id = UUID()
        let json = """
        {"format":"kronos","version":1,"exportedAt":"2026-09-01T10:00:00Z","areas":[],"projects":[],
         "labels":[],"rules":[],"savedViews":[],"tasks":[{"id":"\(id.uuidString)","title":"Old","notes":"",
         "status":0,"priority":0,"depth":0,"dread":false,"sortIndex":0,"needsTriage":false,"labelIDs":[],
         "subtasks":[],"createdAt":"2026-09-01T10:00:00Z","updatedAt":"2026-09-01T10:00:00Z"}]}
        """
        let s = try TaskStore(inMemory: true)
        _ = try KronosImporter(store: s).importData(Data(json.utf8), mode: .merge)
        let t = try #require(s.task(id))
        #expect(t.triageFilledFieldsRaw == "" && t.lockedFieldsRaw == "")
        #expect(t.reviewRaw == 0 && t.assigneeRaw == 0)
        #expect(t.plannedDay == nil && t.carryCount == 0)
        #expect(t.contextJSON == nil && t.resultJSON == nil && t.agentID == nil)
        #expect((t.attachments ?? []).isEmpty)
    }
}
