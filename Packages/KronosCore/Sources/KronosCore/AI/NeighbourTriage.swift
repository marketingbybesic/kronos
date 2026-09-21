// The deterministic fallback used when AI is off (or every candidate fails):
// a weighted vote of the neighbours `TriageContextBuilder` found, instead of
// the old context-blind deterministic triage. Pure, synchronous, no network —
// `AIRouter` uses this as its LAST resort in place of `TriageResult.deterministic`.

import Foundation

public enum NeighbourTriage {

    /// A neighbour needs at least this many peers agreeing (by similarity
    /// weight) before a field is set at all; below it the field is left
    /// unset rather than guessed from one lookalike task. Two neighbours
    /// each contributing weight 1.0 clears this; one neighbour never does.
    static let minAgreeingWeight = 1.5
    /// Neighbours voting for the SAME value need to be at least this many
    /// before a field counts as "agreeing" — one similar task with a random
    /// priority is not agreement, it is a sample size of one.
    static let minAgreeingCount = 2

    /// - Parameters:
    ///   - title, notes: the new task's own text.
    ///   - context: neighbours from `TriageContextBuilder.build`.
    ///   - today: for the explicit-date-word deadline check.
    /// - Returns: `TriageResult` with `isDeterministic == true`; any field
    ///   the vote could not agree on falls back to the same neutral default
    ///   `TriageResult.deterministic` already used (priority none, depth
    ///   shallow, admin/15min), so a brand-new list with zero neighbours
    ///   behaves exactly as it always did.
    public static func infer(title: String, notes: String, context: TriageContext,
                             today: Int) -> TriageResult {
        let language = detectLanguage(title)
        let firstMove = DeterministicFirstMove.generate(title: title, firstMoveURL: nil,
                                                         hasOpenSubtask: false,
                                                         notesNonEmpty: !notes.isEmpty,
                                                         dread: false, language: language)

        let votedPriority = vote(context.examples, weight: weight(for:in:), value: \.priority)
        let votedEffort = vote(context.examples, weight: weight(for:in:), value: \.effort)
        let votedDepth = vote(context.examples, weight: weight(for:in:), value: \.depth)
        let votedProject = voteProject(context.examples)

        let due = explicitDate(in: title + " " + notes, today: today)

        // The "why" line counts only the neighbours that actually agreed on
        // the field it names — never a generic "how many neighbours exist"
        // number, which could overstate the agreement: every suggestion says
        // why, and the why must be true.
        let reasonLine: String?
        if let project = votedProject {
            reasonLine = reason(for: project, count: agreeingCount(context.examples, on: \.projectName, equalTo: project))
        } else if let priority = votedPriority {
            reasonLine = reason(for: nil, count: agreeingCount(context.examples, on: \.priority, equalTo: priority))
        } else if let effort = votedEffort {
            reasonLine = reason(for: nil, count: agreeingCount(context.examples, on: \.effort, equalTo: effort))
        } else if let depth = votedDepth {
            reasonLine = reason(for: nil, count: agreeingCount(context.examples, on: \.depth, equalTo: depth))
        } else {
            reasonLine = nil
        }

        let depth: TriageResult.Depth = (votedDepth ?? .shallow) == .deep ? .deep : .shallow

        return TriageResult(
            project: votedProject,
            priority: (votedPriority ?? .none).rawValue,
            due: due,
            depth: depth,
            estimateMinutes: 15,
            energyKind: .admin,
            firstMove: firstMove,
            labels: [],
            rationale: "",
            proposedRule: nil,
            effort: votedEffort,
            reason: reasonLine,
            version: 0)
    }

    // MARK: - Weighted vote

    /// Sums similarity weight per distinct value and returns the winner only
    /// when it clears BOTH thresholds: total weight >= `minAgreeingWeight`
    /// AND at least `minAgreeingCount` neighbours actually voted that value
    /// (a single very-similar neighbour can clear the weight bar alone,
    /// which is not "neighbours agreeing").
    private static func vote<V: Hashable>(_ examples: [TriageExample],
                                          weight: (TriageExample, [TriageExample]) -> Double,
                                          value: (TriageExample) -> V) -> V? {
        guard examples.count >= minAgreeingCount else { return nil }
        var totals: [V: Double] = [:]
        var counts: [V: Int] = [:]
        for e in examples {
            let v = value(e)
            let w = weight(e, examples)
            totals[v, default: 0] += w
            counts[v, default: 0] += 1
        }
        guard let (winner, total) = totals.max(by: { $0.value < $1.value }) else { return nil }
        guard total >= minAgreeingWeight, (counts[winner] ?? 0) >= minAgreeingCount else { return nil }
        return winner
    }

    /// Every example already carries a similarity-derived rank (its position
    /// in `context.examples`, most-similar first); since `TriageContext` does
    /// not carry the raw score, weight here is a simple recency-independent
    /// rank decay so the closest neighbours count for more without needing a
    /// second pass over `TriageContextBuilder`'s internals.
    private static func weight(for example: TriageExample, in examples: [TriageExample]) -> Double {
        guard let index = examples.firstIndex(of: example) else { return 1 }
        return max(0.5, 1.0 - Double(index) * 0.1)
    }

    private static func voteProject(_ examples: [TriageExample]) -> String? {
        guard examples.count >= minAgreeingCount else { return nil }
        var totals: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for (i, e) in examples.enumerated() {
            guard let p = e.projectName else { continue }
            let w = max(0.5, 1.0 - Double(i) * 0.1)
            totals[p, default: 0] += w
            counts[p, default: 0] += 1
        }
        guard let (winner, total) = totals.max(by: { $0.value < $1.value }) else { return nil }
        guard total >= minAgreeingWeight, (counts[winner] ?? 0) >= minAgreeingCount else { return nil }
        return winner
    }

    /// How many examples' `field` equals `target` — the true "N neighbours
    /// agreed" count for whichever field is driving the reason line.
    private static func agreeingCount<V: Equatable>(_ examples: [TriageExample],
                                                     on field: (TriageExample) -> V, equalTo target: V) -> Int {
        examples.filter { field($0) == target }.count
    }

    private static func reason(for project: String?, count: Int) -> String? {
        guard count >= minAgreeingCount else { return nil }
        if let project {
            return "Like \(count) similar \(project) tasks"
        }
        return "Like \(count) similar tasks already in your list"
    }

    // MARK: - Deadline: explicit date words only, NEVER inferred from neighbours

    /// Reuses `QuickAddParser`'s own date grammar (relative keywords +
    /// ISO date) so "explicit date words" means exactly one thing across the
    /// whole app. Neighbours never contribute a due date — a deadline is
    /// either stated in this task's own text or absent, by design.
    private static func explicitDate(in text: String, today: Int) -> String? {
        let parsed = QuickAddParser().parse(text, projects: [], today: today)
        guard let day = parsed.dueDay else { return nil }
        return Day.iso(day)
    }
}
