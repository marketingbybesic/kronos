import Testing
import Foundation
@testable import KronosCore

/// `TriageContextBuilder` (similarity ranking) and `NeighbourTriage` (the
/// deterministic weighted vote that replaces the old context-blind fallback).
struct TriageContextTests {

    private func source(_ title: String, project: String? = nil, priority: KPriority = .none,
                        effort: KEffort = .none, depth: KDepth = .unknown, open: Bool = true,
                        recency: Double = 0) -> TriageExampleSource {
        TriageExampleSource(title: title, projectName: project, priority: priority, effort: effort,
                            depth: depth, dueDay: nil, open: open, recency: recency)
    }

    // MARK: - Required gate test: contextBuilderRanksSameProjectHigher

    @Test func contextBuilderRanksSameProjectHigher() throws {
        let tasks = [
            source("Nazovi dobavljača za Globex", project: "Globex"),
            source("Nazovi Marka oko cijene", project: "Acme")
        ]
        let context = TriageContextBuilder.build(for: "Nazovi Ivanu oko isporuke za Globex",
                                                  notes: "", from: tasks)
        // Both share the "nazovi" token; the Globex one shares more AND gets
        // the same-project boost, so it must rank first.
        let first = try #require(context.examples.first)
        #expect(first.projectName == "Globex")
    }

    @Test func contextBuilderCapsAtEightAndOrdersBySimilarity() throws {
        let tasks = (1...12).map { i in source("Call Alex about invoice \(i)") }
        let context = TriageContextBuilder.build(for: "Call Alex about invoice 1", notes: "", from: tasks)
        #expect(context.examples.count <= 8)
    }

    @Test func contextBuilderFindsNothingForAnUnrelatedTitle() throws {
        let tasks = [source("Water the plants"), source("Buy milk")]
        let context = TriageContextBuilder.build(for: "Quarterly tax filing review", notes: "", from: tasks)
        #expect(context.examples.isEmpty)
    }

    // MARK: - Required gate test: neighbourTriageVotesPriorityAndEffort

    @Test func neighbourTriageVotesPriorityAndEffort() throws {
        let examples = [
            TriageExample(title: "Acme invoice 1", projectName: "Acme", priority: .high, effort: .s,
                         depth: .shallow, hadDeadline: false, open: true, recency: 3),
            TriageExample(title: "Acme invoice 2", projectName: "Acme", priority: .high, effort: .s,
                         depth: .shallow, hadDeadline: false, open: true, recency: 2),
            TriageExample(title: "Acme invoice 3", projectName: "Acme", priority: .high, effort: .s,
                         depth: .shallow, hadDeadline: false, open: false, recency: 1)
        ]
        let context = TriageContext(examples: examples)
        let result = NeighbourTriage.infer(title: "Acme invoice 4", notes: "", context: context,
                                           today: Day.today())
        #expect(result.priority == KPriority.high.rawValue)
        #expect(result.effort == .s)
        #expect(result.isDeterministic)
        #expect(result.reason != nil)
    }

    // MARK: - Required gate test: neighbourTriageLeavesFieldUnsetWithoutAgreement

    @Test func neighbourTriageLeavesFieldUnsetWithoutAgreement() throws {
        // Three neighbours that all disagree with each other on every field:
        // no value can reach the minimum agreeing count of 2.
        let examples = [
            TriageExample(title: "Task A", projectName: "Acme", priority: .high, effort: .s,
                         depth: .shallow, hadDeadline: false, open: true, recency: 3),
            TriageExample(title: "Task B", projectName: "Globex", priority: .low, effort: .l,
                         depth: .deep, hadDeadline: false, open: true, recency: 2),
            TriageExample(title: "Task C", projectName: "Initech", priority: .urgent, effort: .xl,
                         depth: .deep, hadDeadline: false, open: true, recency: 1)
        ]
        let context = TriageContext(examples: examples)
        let result = NeighbourTriage.infer(title: "Task D", notes: "", context: context, today: Day.today())
        #expect(result.priority == KPriority.none.rawValue)
        #expect(result.effort == nil)
        #expect(result.project == nil)
    }

    @Test func neighbourTriageNeverInventsADeadlineFromNeighbours() throws {
        let examples = [
            TriageExample(title: "Acme invoice 1", projectName: "Acme", priority: .high, effort: .s,
                         depth: .shallow, hadDeadline: true, open: true, recency: 2),
            TriageExample(title: "Acme invoice 2", projectName: "Acme", priority: .high, effort: .s,
                         depth: .shallow, hadDeadline: true, open: true, recency: 1)
        ]
        let context = TriageContext(examples: examples)
        // The new task's own text has no date word, so due must stay nil even
        // though every neighbour "hadDeadline".
        let result = NeighbourTriage.infer(title: "Acme invoice 3", notes: "", context: context,
                                           today: Day.today())
        #expect(result.due == nil)
    }

    @Test func neighbourTriageReadsAnExplicitDateWordFromItsOwnText() throws {
        let today = Day.today()
        let result = NeighbourTriage.infer(title: "Call Alex tomorrow", notes: "", context: .empty, today: today)
        #expect(result.due == Day.iso(today + 1))
    }

    @Test func oneNeighbourAloneNeverDecidesAField() throws {
        let examples = [
            TriageExample(title: "Acme invoice 1", projectName: "Acme", priority: .high, effort: .s,
                         depth: .shallow, hadDeadline: false, open: true, recency: 1)
        ]
        let result = NeighbourTriage.infer(title: "Acme invoice 2", notes: "", context: TriageContext(examples: examples),
                                           today: Day.today())
        #expect(result.priority == KPriority.none.rawValue)
        #expect(result.effort == nil)
    }
}
