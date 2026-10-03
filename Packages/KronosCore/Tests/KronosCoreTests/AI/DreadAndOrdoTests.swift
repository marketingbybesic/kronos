import Testing
import Foundation
@testable import KronosCore

private func triageJSON(dreadFragment: String) -> Data {
    Data("""
    {"project":null,"priority":2,"due":null,"depth":"shallow","estimateMinutes":15,
     "energyKind":"admin","firstMove":"Open the invoice folder and find September.","labels":[],
     "rationale":"One document and one email, no preparation needed."\(dreadFragment)}
    """.utf8)
}

/// The dread key of the triage schema.
struct DreadKeyTests {

    private func decode(_ fragment: String) throws -> TriageResult {
        try JSONDecoder().decode(TriageResult.self, from: triageJSON(dreadFragment: fragment))
    }

    @Test func decodeTable() throws {
        let table: [(String, Bool?)] = [
            ("", nil),                         // key absent
            (",\"dread\":null", nil),
            (",\"dread\":true", true),
            (",\"dread\":false", false),
            (",\"dread\":1", true),
            (",\"dread\":0", false),
            (",\"dread\":7", nil),             // not a flag: no opinion, reply still usable
            (",\"dread\":\"yes\"", nil),
        ]
        for (fragment, expected) in table {
            #expect(try decode(fragment).dread == expected, "fragment \(fragment)")
        }
    }

    @Test func theValidatedResultKeepsTheKey() throws {
        let data = triageJSON(dreadFragment: ",\"dread\":true")
        let validated = try AIRouter.validateTriage(data, projectNames: [], labelNames: [], today: 20_000)
        #expect(validated.dread == true)
        let without = try AIRouter.validateTriage(triageJSON(dreadFragment: ""), projectNames: [], labelNames: [], today: 20_000)
        #expect(without.dread == nil)
    }

    @Test func aRouterReplyWithTheKeyReachesTheCaller() async throws {
        let reply = String(decoding: triageJSON(dreadFragment: ",\"dread\":true"), as: UTF8.self)
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(reply)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        let result = try await router.triage(title: "Call the landlord about the deposit", notes: "",
                                             projectNames: [], labelNames: [], today: 20_000,
                                             lockedFields: [], context: .empty)
        #expect(result.dread == true)
        #expect(!result.isDeterministic)
    }

    @Test func thePromptAsksForTheKeyAndItsExampleStillDecodes() throws {
        #expect(PromptRequiredKeys.triageNullable.contains("dread"))
        #expect(PromptTemplates.triageSystem.contains("- dread: true, false or null."))
        #expect(PromptTemplates.triageSystem.contains("conflict, money they owe or are owed, or an apology"))
        #expect(PromptTemplates.retriageSystem.contains("- dread: true, false or null."))
        let example = try #require(PromptTemplates.triageSystem.components(separatedBy: "Example (values are illustrative, not a rule to copy):\n").last)
        let json = try #require(example.components(separatedBy: "\n\nReturn a single JSON object").first)
        let decoded = try JSONDecoder().decode(TriageResult.self, from: Data(json.utf8))
        #expect(decoded.dread == nil)
        #expect(json.contains("\"dread\":null"))
    }

    @Test func theFieldGuardKnowsTheKey() {
        #expect(TriageField.allCases.contains(.dread))
        let result = TriageResult(project: nil, priority: 0, due: nil, depth: .shallow, estimateMinutes: 15,
                                  energyKind: .admin, firstMove: "Open the file.", labels: [], rationale: "x", dread: true)
        #expect(TriageFieldGuard.apply(result, lockedFields: [.dread]).mayWrite(.dread) == false)
        #expect(TriageFieldGuard.apply(result, lockedFields: []).mayWrite(.dread))
    }
}

/// "Tell Up next ...": the reorder is a preview, never a write.
@MainActor
struct OrdoResortPreviewTests {

    private let a = OrdoCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, title: "Write the report")
    private let b = OrdoCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, title: "Globex bond questions")
    private let c = OrdoCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!, title: "Book the dentist")

    private func makeRouter(_ reply: String) -> (AIRouter, FixtureAIClient) {
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(reply)])
        return (AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)]), client)
    }

    @Test func aValidPermutationComesBackAsOrderedIds() async {
        let (router, client) = makeRouter(#"{"order":[2,3,1],"explanation":"Globex first.","proposedRule":null}"#)
        let ids = await router.resortOrdo(instruction: "Globex first", candidates: [a, b, c])
        #expect(ids == [b.id, c.id, a.id])
        let sent = (await client.callLog).first?.messages.first { $0.role == "user" }?.content ?? ""
        #expect(sent.contains("1. Write the report"))
        #expect(sent.contains("2. Globex bond questions"))
        #expect(sent.contains("Globex first"))
    }

    @Test func thePreviewCarriesTheExplanationAndTheChangedFlag() async {
        let (router, _) = makeRouter(#"{"order":[2,3,1],"explanation":"Globex first.","proposedRule":null}"#)
        let preview = await router.resortOrdoPreview(instruction: "Globex first", candidates: [a, b, c])
        #expect(preview.changed)
        #expect(preview.explanation == "Globex first.")
        let (same, _) = makeRouter(#"{"order":[1,2,3],"explanation":"Already in that order.","proposedRule":null}"#)
        let unchanged = await same.resortOrdoPreview(instruction: "as it is", candidates: [a, b, c])
        #expect(!unchanged.changed)
        #expect(unchanged.ids == [a.id, b.id, c.id])
    }

    @Test func badAnswersLeaveTheOrderAlone() async {
        let original = [a.id, b.id, c.id]
        let replies = [
            #"{"order":[2,2,1],"explanation":"dup","proposedRule":null}"#,         // not a permutation
            #"{"order":[1,2],"explanation":"short","proposedRule":null}"#,         // missing a position
            #"{"order":[3,2,1],"explanation":"Not a queue instruction","proposedRule":null}"#,
            "not json at all",
        ]
        for reply in replies {
            let (router, _) = makeRouter(reply)
            #expect(await router.resortOrdo(instruction: "do something", candidates: [a, b, c]) == original, "\(reply)")
        }
    }

    @Test func noCallForAnEmptyInstructionASingleTaskOrAIOff() async {
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(#"{"order":[1],"explanation":"x","proposedRule":null}"#)])
        let on = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        #expect(await on.resortOrdo(instruction: "   ", candidates: [a, b]) == [a.id, b.id])
        #expect(await on.resortOrdo(instruction: "first", candidates: [a]) == [a.id])
        let off = AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: client)])
        #expect(await off.resortOrdo(instruction: "first", candidates: [a, b]) == [a.id, b.id])
        #expect(await client.callCount == 0)
    }

    @Test func aLongQueueKeepsItsTailInPlace() async {
        let many = (0..<35).map { OrdoCandidate(id: UUID(), title: "Task \($0)") }
        let reversedHead = (1...30).reversed().map(String.init).joined(separator: ",")
        let (router, client) = makeRouter(#"{"order":[\#(reversedHead)],"explanation":"Reversed.","proposedRule":null}"#)
        let ids = await router.resortOrdo(instruction: "reverse", candidates: many)
        #expect(ids == many.prefix(30).reversed().map(\.id) + many.suffix(5).map(\.id))
        let sent = (await client.callLog).first?.messages.first { $0.role == "user" }?.content ?? ""
        #expect(!sent.contains("Task 30"))
    }

    @Test func thePreviewWritesNothingToTheStore() async throws {
        let store = try TaskStore(inMemory: true)
        let t1 = store.create(title: "Write the report")
        let t2 = store.create(title: "Globex bond questions")
        let t3 = store.create(title: "Book the dentist")
        let before = store.allTasks().map { ($0.id, $0.title, $0.ordoIndex, $0.sortIndex, $0.updatedAt) }
        let depth = store.undoDepth

        let candidates = [t1, t2, t3].map { OrdoCandidate(id: $0.id, title: $0.title) }
        let (router, _) = makeRouter(#"{"order":[2,3,1],"explanation":"Globex first.","proposedRule":null}"#)
        let ids = await router.resortOrdo(instruction: "Globex first", candidates: candidates)

        #expect(ids == [t2.id, t3.id, t1.id])
        let after = store.allTasks().map { ($0.id, $0.title, $0.ordoIndex, $0.sortIndex, $0.updatedAt) }
        #expect(before.count == after.count)
        for (x, y) in zip(before, after) {
            #expect(x.0 == y.0 && x.1 == y.1 && x.2 == y.2 && x.3 == y.3 && x.4 == y.4)
        }
        #expect(store.undoDepth == depth)
    }
}
