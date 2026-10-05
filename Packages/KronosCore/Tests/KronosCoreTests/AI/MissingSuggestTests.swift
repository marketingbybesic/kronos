import Testing
import Foundation
@testable import KronosCore

private let effortReply = """
{"project":null,"priority":2,"due":null,"depth":"deep","estimateMinutes":45,"energyKind":"creative",
 "firstMove":"Open the draft and read the first section.","labels":[],
 "rationale":"A focused afternoon of writing.","effort":3}
"""

/// "Suggest with AI" in the missing group: the existing triage pipeline run for one field of many
/// tasks, scripted with `FixtureAIClient` (no network), applied in one undo step.
@MainActor
@Suite("MissingSuggestTests")
struct MissingSuggestTests {

    private func world() throws -> (store: TaskStore, a: KTask, b: KTask, locked: KTask) {
        let s = try TaskStore(inMemory: true)
        let a = s.createNoUndo(title: "Write the quarterly report")
        let b = s.createNoUndo(title: "Plan the offsite agenda")
        let locked = s.createNoUndo(title: "Draft the board memo")
        locked.lockedFieldsRaw = TriageFieldKind.encode([.effort])
        s.clearUndoHistory()
        return (s, a, b, locked)
    }

    private func subjects(_ tasks: [KTask]) -> [MissingSuggest.Subject] {
        tasks.map { MissingSuggest.Subject(id: $0.id, title: $0.title, notes: $0.notes, locked: $0.lockedFields) }
    }

    private func router(_ client: FixtureAIClient, mode: AIMode = .allowAny) -> AIRouter {
        AIRouter(mode: mode, candidates: [AIRoutedCandidate(client: client)], chainBudgetSeconds: 5)
    }

    @Test("effort suggestions come from the model, skip the locked task, and write nothing")
    func suggestsOnlyTheMissingFieldForUnlockedTasks() async throws {
        let w = try world()
        let client = FixtureAIClient(modelID: "claude-sonnet-5",
                                     script: Array(repeating: .content(effortReply), count: 3))
        let out = await MissingSuggest.suggest(for: subjects([w.a, w.b, w.locked]), kind: .effort, examples: [],
                                               projectNames: [], labelNames: [], today: Day.today(),
                                               router: router(client), modelID: "claude-sonnet-5")
        #expect(out.map(\.taskID) == [w.a.id, w.b.id])   // the locked task is not even asked about
        #expect(out.allSatisfy { $0.value == .effort(.m) && $0.kind == .effort && !$0.isNeighbourSourced })
        #expect(await client.callCount == 2)
        // Nothing is written until the person accepts.
        #expect(w.a.effort == .none && w.b.effort == .none)
        #expect(w.store.undoDepth == 0)
    }

    @Test("accepting fills only the missing field of every task in ONE undo step, and one undo restores all")
    func acceptIsOneUndoStep() async throws {
        let w = try world()
        let client = FixtureAIClient(modelID: "claude-sonnet-5",
                                     script: Array(repeating: .content(effortReply), count: 3))
        let out = await MissingSuggest.suggest(for: subjects([w.a, w.b, w.locked]), kind: .effort, examples: [],
                                               projectNames: [], labelNames: [], today: Day.today(),
                                               router: router(client), modelID: "claude-sonnet-5")
        let filled = MissingSuggest.apply(out, to: w.store)
        #expect(Set(filled) == [w.a.id, w.b.id])
        #expect(w.store.undoDepth == 1)
        #expect(w.store.task(w.a.id)?.effort == .m && w.store.task(w.b.id)?.effort == .m)
        // The reply also carried priority 2, depth, estimate and a first move: none of it is written.
        #expect(w.store.task(w.a.id)?.priority == KPriority.none)
        #expect(w.store.task(w.a.id)?.depth == KDepth.unknown)
        #expect(w.store.task(w.a.id)?.estimateMinutes == nil)
        #expect(w.store.task(w.a.id)?.firstMove == nil)
        // The locked task keeps its (empty) value.
        #expect(w.store.task(w.locked.id)?.effort == KEffort.none)

        w.store.undo()
        #expect(w.store.task(w.a.id)?.effort == KEffort.none && w.store.task(w.b.id)?.effort == KEffort.none)
        #expect(w.store.undoDepth == 0)
    }

    @Test("a value the owner set since the suggestion was made is never overwritten")
    func fillOnly() async throws {
        let w = try world()
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(effortReply)])
        let out = await MissingSuggest.suggest(for: subjects([w.a]), kind: .effort, examples: [],
                                               projectNames: [], labelNames: [], today: Day.today(),
                                               router: router(client), modelID: "claude-sonnet-5")
        w.a.effortRaw = KEffort.xl.rawValue
        let filled = MissingSuggest.apply(out, to: w.store)
        #expect(filled.isEmpty)
        #expect(w.store.task(w.a.id)?.effort == .xl)
    }

    @Test("without a router the neighbour vote answers, and a field it did not decide is not a suggestion")
    func noRouterNoGuess() async throws {
        let w = try world()
        let out = await MissingSuggest.suggest(for: subjects([w.a, w.b]), kind: .effort, examples: [],
                                               projectNames: [], labelNames: [], today: Day.today(),
                                               router: nil, modelID: nil)
        #expect(out.isEmpty)
    }

    @Test("a router in Off mode sends nothing; the same router allowed does (positive control)")
    func offModeSendsNothing() async throws {
        let w = try world()
        let off = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(effortReply)])
        _ = await MissingSuggest.suggest(for: subjects([w.a]), kind: .effort, examples: [], projectNames: [],
                                         labelNames: [], today: Day.today(), router: router(off, mode: .off), modelID: "m")
        #expect(await off.callCount == 0)
        let on = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(effortReply)])
        _ = await MissingSuggest.suggest(for: subjects([w.a]), kind: .effort, examples: [], projectNames: [],
                                         labelNames: [], today: Day.today(), router: router(on), modelID: "m")
        #expect(await on.callCount == 1)
    }

    @Test("at most twenty tasks are asked about in one batch")
    func batchLimit() async throws {
        let s = try TaskStore(inMemory: true)
        let many = (0..<25).map { s.createNoUndo(title: "Task number \($0)") }
        let client = FixtureAIClient(modelID: "claude-sonnet-5",
                                     script: Array(repeating: .content(effortReply), count: 25))
        let out = await MissingSuggest.suggest(for: subjects(many), kind: .effort, examples: [], projectNames: [],
                                               labelNames: [], today: Day.today(), router: router(client), modelID: "m")
        #expect(out.count == MissingSuggest.batchLimit)
        #expect(await client.callCount == MissingSuggest.batchLimit)
        #expect(s.undoDepth == 0)
    }

    @Test("a project is suggested only when the model names an existing one")
    func projectSuggestion() async throws {
        let w = try world()
        let acme = w.store.createProject(name: "Acme")
        let reply = effortReply.replacingOccurrences(of: "\"project\":null", with: "\"project\":\"Acme\"")
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(reply)])
        let out = await MissingSuggest.suggest(for: subjects([w.a]), kind: .project, examples: [],
                                               projectNames: ["Acme"], labelNames: [], today: Day.today(),
                                               router: router(client), modelID: "m")
        #expect(out.first?.value == .project(name: "Acme"))
        _ = MissingSuggest.apply(out, to: w.store)
        #expect(w.store.task(w.a.id)?.project?.id == acme.id)
    }
}
