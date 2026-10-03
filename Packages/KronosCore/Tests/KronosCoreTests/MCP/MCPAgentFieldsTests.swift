import Testing
import Foundation
@testable import KronosCore

/// Agent-facing writes: dread, effort, energyKind, links, plannedDay, notesAppend, labelsAdd/Remove,
/// externalID idempotency, source, and house-rule tools.
@MainActor
@Suite struct MCPAgentFieldsTests {

    private func make(today: Int = Day.parseISO("2026-10-10")!) throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        return (store, MCPDispatcher(store: store, ranking: RankingEngine(), today: { today }))
    }

    private func envelope(_ tool: String, _ args: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["name": tool, "arguments": args])
    }

    private func call(_ d: MCPDispatcher, _ tool: String, _ args: [String: Any], client: String? = nil) throws -> (isError: Bool, body: [String: Any]) {
        let rpc = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                              "params": ["name": tool, "arguments": args]])
        let reply = d.handleBody(rpc, client: client)
        let data = try #require(reply.body)
        let top = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let res = try #require(top["result"] as? [String: Any])
        return ((res["isError"] as? Bool) ?? false, res["structuredContent"] as? [String: Any] ?? [:])
    }

    private func taskID(_ body: [String: Any]) throws -> UUID {
        let t = try #require(body["task"] as? [String: Any])
        let raw = try #require(t["id"] as? String)
        return try #require(UUID(uuidString: raw))
    }

    // MARK: item fields

    @Test func createSetsDreadEffortEnergyLinksAndPlannedDayAndReadsThemBack() throws {
        let (store, d) = try make()
        let r = try call(d, "create_task", [
            "title": "File taxes", "dread": true, "effort": "l", "energyKind": "admin",
            "links": ["https://example.com/a", "http://example.org/b"], "plannedDay": "2026-10-12",
            "firstMove": "Open the mail and read paragraph 2"])
        #expect(!r.isError)
        let id = try taskID(r.body)
        let t = try #require(store.task(id))
        #expect(t.dread && t.effort == .l && t.energyKind == .admin)
        #expect(t.plannedDay == Day.parseISO("2026-10-12"))
        #expect(t.dueDay == nil, "plannedDay must never touch the due day")

        let got = try call(d, "get_task", ["id": id.uuidString])
        let task = try #require(got.body["task"] as? [String: Any])
        #expect(task["dread"] as? Bool == true)
        #expect(task["effort"] as? String == "l")
        #expect(task["energyKind"] as? String == "admin")
        #expect(task["plannedDay"] as? String == "2026-10-12")
        #expect(task["links"] as? [String] == ["https://example.com/a", "http://example.org/b"])
        #expect(task["source"] as? String == "mcp")
        #expect(store.lockedFields(of: id).isSuperset(of: [.effort, .energyKind]), "explicit fields are locked against triage")
    }

    @Test func aTaskWithoutThoseFieldsShowsTheDefaultsPositiveControl() throws {
        let (_, d) = try make()
        let r = try call(d, "create_task", ["title": "Plain"])
        let task = try #require(r.body["task"] as? [String: Any])
        #expect(task["dread"] as? Bool == false)
        #expect(task["effort"] as? String == "none")
        #expect(task["links"] as? [String] == [])
        #expect(task["plannedDay"] == nil, "an unset plan is omitted, not a value")
    }

    @Test func updateSetsTheNewFieldsAndClearsNullableOnes() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "T")
        _ = try call(d, "update_task", ["id": t.id.uuidString, "dread": true, "effort": "xs", "energyKind": "people", "plannedDay": "2026-10-11"])
        #expect(store.task(t.id)?.dread == true && store.task(t.id)?.effort == .xs)
        #expect(store.task(t.id)?.energyKind == .people)
        #expect(store.task(t.id)?.plannedDay == Day.parseISO("2026-10-11"))
        _ = try call(d, "update_task", ["id": t.id.uuidString, "energyKind": NSNull(), "plannedDay": NSNull(), "dread": false])
        #expect(store.task(t.id)?.energyKind == nil)
        #expect(store.task(t.id)?.plannedDay == nil)
        #expect(store.task(t.id)?.dread == false)
    }

    @Test func notesAppendAddsAfterANewlineAndNeverReplaces() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "T", notes: "first")
        _ = try call(d, "update_task", ["id": t.id.uuidString, "notesAppend": "second"])
        #expect(store.task(t.id)?.notes == "first\nsecond")
        let empty = store.createNoUndo(title: "E")
        _ = try call(d, "update_task", ["id": empty.id.uuidString, "notesAppend": "only"])
        #expect(store.task(empty.id)?.notes == "only", "no leading newline on empty notes")
    }

    @Test func notesAppendBeyondTheCapIsRejectedAndChangesNothing() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "T", notes: String(repeating: "a", count: MCPLimits.maxNotesCharacters - 3))
        let r = try call(d, "update_task", ["id": t.id.uuidString, "notesAppend": "bbbb"])
        #expect(r.isError && (r.body["message"] as? String)?.contains("notes") == true)
        #expect(store.task(t.id)?.notes.count == MCPLimits.maxNotesCharacters - 3)
        // Exactly at the cap (1 newline + 2 chars) is accepted.
        #expect(try call(d, "update_task", ["id": t.id.uuidString, "notesAppend": "bb"]).isError == false)
        #expect(store.task(t.id)?.notes.count == MCPLimits.maxNotesCharacters)
    }

    @Test func labelsAddAndRemoveChangeOnlyThoseLabels() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "T")
        _ = try call(d, "update_task", ["id": t.id.uuidString, "labels": ["alpha", "beta"]])
        _ = try call(d, "update_task", ["id": t.id.uuidString, "labelsAdd": ["gamma", "alpha"], "labelsRemove": ["BETA"]])
        let names = Set((store.task(t.id)?.labels ?? []).map(\.name))
        #expect(names == ["alpha", "gamma"], "added gamma once, kept alpha, removed beta case-insensitively")
    }

    @Test func linksAreAddedWithoutDuplicatesAndNeverRemoved() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "T")
        _ = try call(d, "update_task", ["id": t.id.uuidString, "links": ["https://a.example/x"]])
        _ = try call(d, "update_task", ["id": t.id.uuidString, "links": ["https://a.example/x", "https://b.example/y"]])
        let urls = (store.task(t.id)?.attachments ?? []).compactMap(\.url).sorted()
        #expect(urls == ["https://a.example/x", "https://b.example/y"])
        _ = try call(d, "update_task", ["id": t.id.uuidString, "title": "renamed"])
        #expect((store.task(t.id)?.attachments ?? []).count == 2)
    }

    @Test func onlyHttpAndHttpsLinksAreAcceptedAndABadOneWritesNothing() throws {
        let (store, d) = try make()
        for bad in ["ftp://x.example/a", "javascript:alert(1)", "not a url", "file:///etc/passwd", "https://"] {
            let r = try call(d, "create_task", ["title": "L", "links": ["https://ok.example", bad]])
            #expect(r.isError, "\(bad) was accepted")
            #expect((r.body["message"] as? String)?.contains("links") == true)
        }
        #expect(store.allTasks().isEmpty)
        #expect(try call(d, "create_task", ["title": "L", "links": ["https://ok.example"]]).isError == false)
        let tooMany = (0...MCPLimits.maxLinks).map { "https://x.example/\($0)" }
        #expect(try call(d, "create_task", ["title": "L2", "links": tooMany]).isError)
    }

    @Test func plannedDayMustBeADate() throws {
        let (store, d) = try make()
        let r = try call(d, "create_task", ["title": "T", "plannedDay": "tomorrow"])
        #expect(r.isError && (r.body["message"] as? String)?.contains("plannedDay") == true)
        #expect(store.allTasks().isEmpty)
    }

    @Test func aPlannedTaskAppearsInTheTodayViewWithoutADueDate() throws {
        let (store, d) = try make(today: Day.parseISO("2026-10-10")!)
        let planned = store.createNoUndo(title: "planned")
        let later = store.createNoUndo(title: "later")
        _ = try call(d, "update_task", ["id": planned.id.uuidString, "plannedDay": "2026-10-10"])
        _ = try call(d, "update_task", ["id": later.id.uuidString, "plannedDay": "2026-10-11"])
        let r = try call(d, "list_tasks", ["view": "today"])
        let titles = (r.body["tasks"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        #expect(titles == ["planned"], "planned for today is in; planned for tomorrow is not")
    }

    // MARK: item / item idempotency and identity

    @Test func twoIdenticalExternalIDCallsCreateOneTask() throws {
        let (store, d) = try make()
        let first = try call(d, "create_task", ["title": "Sync", "externalID": "job-1"], client: "codex")
        let second = try call(d, "create_task", ["title": "Sync", "externalID": "job-1"], client: "codex")
        #expect(first.body["created"] as? Bool == true)
        #expect(second.body["created"] as? Bool == false)
        #expect(try taskID(first.body) == taskID(second.body))
        #expect(store.allTasks().count == 1)
    }

    @Test func aRetryWithDifferentFieldsReturnsTheOriginalUntouched() throws {
        let (store, d) = try make()
        let id = try taskID(call(d, "create_task", ["title": "Original", "externalID": "k", "priority": "low"]).body)
        let retry = try call(d, "create_task", ["title": "Changed", "externalID": "k", "priority": "urgent"])
        #expect(try taskID(retry.body) == id)
        #expect(store.task(id)?.title == "Original" && store.task(id)?.priority == .low)
    }

    @Test func theSameExternalIDFromAnotherAgentIsAnotherTaskAndWithoutOneNothingDedupes() throws {
        let (store, d) = try make()
        _ = try call(d, "create_task", ["title": "A", "externalID": "x"], client: "codex")
        _ = try call(d, "create_task", ["title": "A", "externalID": "x"], client: "relay")
        #expect(store.allTasks().count == 2)
        // Positive control: no externalID means two calls, two tasks.
        _ = try call(d, "create_task", ["title": "B"], client: "codex")
        _ = try call(d, "create_task", ["title": "B"], client: "codex")
        #expect(store.allTasks().count == 4)
    }

    @Test func aDeletedTaskDoesNotBlockItsExternalID() throws {
        let (store, d) = try make()
        let id = try taskID(call(d, "create_task", ["title": "A", "externalID": "x"]).body)
        store.softDeleteNoUndo(id)
        let again = try call(d, "create_task", ["title": "A", "externalID": "x"])
        #expect(again.body["created"] as? Bool == true)
    }

    @Test func aBlankOrOversizedExternalIDIsInvalid() throws {
        let (store, d) = try make()
        #expect(try call(d, "create_task", ["title": "A", "externalID": "  "]).isError)
        #expect(try call(d, "create_task", ["title": "A", "externalID": String(repeating: "k", count: 201)]).isError)
        #expect(store.allTasks().isEmpty)
    }

    @Test func tasksCarryTheCallingAgentAsSource() throws {
        let (store, d) = try make()
        let named = try taskID(call(d, "create_task", ["title": "N"], client: "Codex").body)
        let anon = try taskID(call(d, "create_task", ["title": "A"]).body)
        #expect(store.task(named)?.source == "agent:Codex")
        #expect(store.task(anon)?.source == "mcp")
        let full = try call(d, "get_task", ["id": named.uuidString])
        #expect((full.body["task"] as? [String: Any])?["source"] as? String == "agent:Codex")
    }

    @Test func aHostileClientNameIsSanitizedBeforeItIsStored() throws {
        let (store, d) = try make()
        let id = try taskID(call(d, "create_task", ["title": "N"], client: "ev\r\nil<script>").body)
        let source = try #require(store.task(id)?.source)
        #expect(source.hasPrefix("agent:") && !source.contains("\n") && !source.contains("<"))
        let long = try taskID(call(d, "create_task", ["title": "L"], client: String(repeating: "x", count: 200)).body)
        #expect(store.task(long)?.source == "agent:" + String(repeating: "x", count: 40))
        let empty = try taskID(call(d, "create_task", ["title": "E"], client: "  --  ").body)
        #expect(store.task(empty)?.source == "mcp")
    }

    @Test func theClientNameDoesNotLeakIntoTheNextRequest() throws {
        let (store, d) = try make()
        _ = try call(d, "create_task", ["title": "A"], client: "codex")
        let next = try taskID(call(d, "create_task", ["title": "B"]).body)
        #expect(store.task(next)?.source == "mcp")
    }

    // MARK: item rules

    @Test func aRuleAddedOverMCPStartsInactiveAndIsMarkedAsAnAgents() throws {
        let (store, d) = try make()
        let r = try call(d, "rules_add", ["text": "No meetings before noon", "scope": "triage"])
        #expect(!r.isError)
        let rule = try #require(r.body["rule"] as? [String: Any])
        #expect(rule["isActive"] as? Bool == false)
        #expect(rule["source"] as? String == "agent")
        #expect(store.activeRules().isEmpty, "an inactive rule must not reach triage")
        let all = store.allRules(includeInactive: true)
        #expect(all.count == 1 && all[0].sourceRaw == KRule.agentSourceRaw && !all[0].isActive)
    }

    @Test func aManualRuleStaysActiveAndRulesListHidesInactiveByDefault() throws {
        let (store, d) = try make()
        store.addRule(text: "Deep work in the morning", scope: .all, source: .manual)
        _ = try call(d, "rules_add", ["text": "Never schedule on Sundays"])
        let plain = try call(d, "rules_list", [:])
        #expect((plain.body["rules"] as? [[String: Any]])?.count == 1)
        let full = try call(d, "rules_list", ["includeInactive": true])
        let rules = try #require(full.body["rules"] as? [[String: Any]])
        #expect(rules.count == 2)
        #expect(Set(rules.compactMap { $0["source"] as? String }) == ["manual", "agent"])
    }

    @Test func rulesDeleteRemovesTheRuleAndAnUnknownIdIsNotFound() throws {
        let (store, d) = try make()
        let added = try call(d, "rules_add", ["text": "Never schedule on Sundays"])
        let ruleBody = try #require(added.body["rule"] as? [String: Any])
        let rawID = try #require(ruleBody["id"] as? String)
        let id = try #require(UUID(uuidString: rawID))
        let keep = store.addRule(text: "Deep work in the morning", scope: .all, source: .manual)
        let r = try call(d, "rules_delete", ["id": id.uuidString])
        #expect(!r.isError && r.body["deleted"] as? Bool == true)
        #expect(store.allRules(includeInactive: true).map(\.id) == [keep.id])
        let missing = try call(d, "rules_delete", ["id": id.uuidString])
        #expect(missing.isError && missing.body["error"] as? String == "NOT_FOUND")
        #expect(store.allRules(includeInactive: true).count == 1)
    }

    // MARK: item remote agent snippet

    // The snippet builders are compiled out of the public flavour, so is this test.
    #if !KRONOS_PUBLIC
    @Test func theRemoteRelaySnippetRunsTheBridgeOverSshAsRelay() {
        let yaml = MCPSettingsSnippet.bridgeRelayRemoteYAML(host: "mac", bridge: "/Applications/Kronos.app/Contents/MacOS/kronos-mcp")
        #expect(yaml == """
        mcp_servers:
          kronos:
            command: ssh
            args: ["mac", "/Applications/Kronos.app/Contents/MacOS/kronos-mcp", "--agent", "relay"]
        """)
        // Positive control: the local snippet has no ssh in it.
        #expect(!MCPSettingsSnippet.bridgeRelayYAML(bridge: "/x/kronos-mcp").contains("ssh"))
    }
    #endif
}
