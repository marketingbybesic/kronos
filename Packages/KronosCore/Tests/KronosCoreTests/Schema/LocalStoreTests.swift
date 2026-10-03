import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// The device-local store for agents and the activity log: its own file next to the main store,
/// its own container, rows that survive a reopen, defaults as specified.
@MainActor
@Suite("LocalStoreTests")
struct LocalStoreTests {

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func agentAndActivityDefaults() {
        let a = KAgent(slug: "codex", displayName: "Codex")
        #expect(a.rateLimitPerMinute == 60)
        #expect(a.dailyCreateCap == 40)
        #expect(a.maxPendingProposals == 15)
        #expect(a.isEnabled)
        #expect(a.lastSeenAt == nil)
        #expect(a.webhookURL == nil)
        #expect(a.listProjectID == nil)
        let e = KActivity(seq: 1, actor: "agent:codex", verb: "task.create")
        #expect(e.webhookStateRaw == 0)
        #expect(e.webhookAttempts == 0)
        #expect(e.payloadJSON == "")
        #expect(e.taskID == nil)
    }

    @Test func theLocalStoreIsItsOwnFileAndKeepsItsRows() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let taskID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
        do {
            let container = try KronosLocalStore.makeContainer(directory: dir)
            #expect(container.configurations.first?.url.lastPathComponent == "Kronos-local.store")
            let ctx = ModelContext(container)
            let agent = KAgent(slug: "relay", displayName: "Relay", glyph: "H",
                               tokenHash: String(repeating: "a", count: 64), scopesRaw: "read,propose")
            ctx.insert(agent)
            ctx.insert(KActivity(seq: 1, actor: "agent:relay", verb: "task.create", taskID: taskID, agentID: agent.id))
            ctx.insert(KActivity(seq: 2, actor: "me", verb: "task.complete", taskID: taskID))
            try ctx.save()
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Kronos-local.store").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Kronos.store").path),
                "opening the local store never creates the main store")

        let reopened = ModelContext(try KronosLocalStore.makeContainer(directory: dir))
        let agents = try reopened.fetch(FetchDescriptor<KAgent>())
        #expect(agents.map(\.slug) == ["relay"])
        #expect(agents.first?.scopesRaw == "read,propose")
        let events = try reopened.fetch(FetchDescriptor<KActivity>(sortBy: [SortDescriptor(\.seq)]))
        #expect(events.map(\.verb) == ["task.create", "task.complete"])
        #expect(events.allSatisfy { $0.taskID == taskID })
        #expect(events.first?.agentID == agents.first?.id)
    }

    @Test func storeURLSitsInTheGivenDirectory() throws {
        let dir = URL(fileURLWithPath: "/tmp/kronos-example", isDirectory: true)
        #expect(KronosLocalStore.storeURL(in: dir).path == "/tmp/kronos-example/Kronos-local.store")
    }

    @Test func inMemoryContainerForTests() throws {
        let ctx = ModelContext(try KronosLocalStore.makeContainer(inMemory: true))
        ctx.insert(KAgent(slug: "claude-code", displayName: "Claude Code"))
        try ctx.save()
        #expect(try ctx.fetchCount(FetchDescriptor<KAgent>()) == 1)
    }
}
