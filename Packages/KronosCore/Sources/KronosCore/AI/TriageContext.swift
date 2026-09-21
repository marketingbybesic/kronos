// "Triage that fills details from the rest of the list": before classifying
// a new task, look at up to 8 similar tasks already in the store — similarity
// is folded-token overlap (Jaccard) on the title, boosted for a shared
// project — and hand them to the model as worked examples, or vote on them
// directly when AI is off (`NeighbourTriage.swift`).
//
// Pure and synchronous: no store type appears here, only plain values, so
// this is usable from both `AIRouter` (async, off the main actor) and
// `NeighbourTriage` without crossing an actor boundary to fetch anything.

import Foundation

/// One neighbour task, reduced to what triage needs to learn from it.
/// `open` false means done/canceled — still useful signal (a shipped task's
/// final priority/effort), so it is not filtered out, only down-weighted by
/// recency the same as any other example.
public struct TriageExample: Sendable, Equatable {
    public let title: String
    public let projectName: String?
    public let priority: KPriority
    public let effort: KEffort
    public let depth: KDepth
    public let hadDeadline: Bool
    public let open: Bool
    /// Sort key for the recency tie-break: larger is more recent. Tasks pass
    /// `createdAt` as a `TimeInterval`; a fixed value keeps tests deterministic.
    public let recency: Double

    public init(title: String, projectName: String?, priority: KPriority, effort: KEffort,
                depth: KDepth, hadDeadline: Bool, open: Bool, recency: Double) {
        self.title = title
        self.projectName = projectName
        self.priority = priority
        self.effort = effort
        self.depth = depth
        self.hadDeadline = hadDeadline
        self.open = open
        self.recency = recency
    }
}

/// Up to 8 examples for one triage call, most-similar first.
public struct TriageContext: Sendable, Equatable {
    public let examples: [TriageExample]

    public init(examples: [TriageExample]) { self.examples = examples }

    public static let empty = TriageContext(examples: [])

    /// One line per example, in the shape the triage prompt shows the model:
    /// title, project, priority/effort/depth as short words, never raw enum
    /// ordinals a model would have to guess the meaning of.
    public var promptLines: [String] {
        examples.map { e in
            let project = e.projectName.map { " (\($0))" } ?? ""
            let status = e.open ? "open" : "done"
            return "- \(e.title)\(project): priority=\(Self.word(e.priority)), "
                + "effort=\(Self.word(e.effort)), depth=\(Self.word(e.depth)), \(status)"
        }
    }

    private static func word(_ p: KPriority) -> String {
        switch p { case .none: "none"; case .low: "low"; case .medium: "medium"
        case .high: "high"; case .urgent: "urgent" }
    }
    private static func word(_ e: KEffort) -> String {
        switch e { case .none: "none"; case .xs: "xs"; case .s: "s"; case .m: "m"; case .l: "l"; case .xl: "xl" }
    }
    private static func word(_ d: KDepth) -> String {
        switch d { case .unknown: "unknown"; case .shallow: "shallow"; case .deep: "deep" }
    }
}

/// Builds a `TriageContext` from the rest of the list. Pure, synchronous, no
/// network — the same shape as `FirstMoveLint`/`DeterministicFirstMove`.
public enum TriageContextBuilder {

    /// - Parameters:
    ///   - title: the new task's title (and notes) — what similarity is
    ///     measured against.
    ///   - tasks: every candidate neighbour, open or done; the new task
    ///     itself (if it already exists as a row) should be excluded by the
    ///     caller.
    ///   - limit: at most this many examples, most-similar first (8 in
    ///     production; tests pass smaller lists to keep fixtures short).
    public static func build(for title: String, notes: String, from tasks: [TriageExampleSource],
                             limit: Int = 8) -> TriageContext {
        let queryTokens = tokens(title + " " + notes)
        guard !queryTokens.isEmpty else { return .empty }

        let scored: [(TriageExample, Double)] = tasks.compactMap { source in
            let candidateTokens = tokens(source.title)
            let overlap = jaccard(queryTokens, candidateTokens)
            guard overlap > 0 else { return nil }
            var score = overlap
            // Same-project boost (spec: "contextBuilderRanksSameProjectHigher").
            // Cheap proxy for "same project": the candidate's own project name
            // shares a folded token with the query title/notes, which is true
            // whenever the user names the project in the new task's own text
            // (e.g. "...for Globex") and is otherwise a harmless no-op.
            if let project = source.projectName, !tokens(project).isDisjoint(with: queryTokens) {
                score += 0.25
            }
            let example = TriageExample(title: source.title, projectName: source.projectName,
                                        priority: source.priority, effort: source.effort,
                                        depth: source.depth, hadDeadline: source.dueDay != nil,
                                        open: source.open, recency: source.recency)
            return (example, score)
        }

        // Highest score first; recency breaks a tie so two equally-similar
        // neighbours resolve deterministically rather than by array order.
        let ranked = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.recency > b.0.recency
        }
        return TriageContext(examples: ranked.prefix(limit).map(\.0))
    }

    /// Folded, de-duplicated word tokens, stopwords removed — the same
    /// folding `KTextFold` uses, so "Nazovi Ivanu" and "nazovi ivanu" collide.
    static func tokens(_ text: String) -> Set<String> {
        let folded = KTextFold.fold(text)
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return Set(words.filter { $0.count > 1 && !stopwords.contains($0) })
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "to", "for", "of", "in", "on", "at", "with",
        "i", "u", "za", "na", "je", "se", "da", "ne", "s", "o", "od", "do", "sa"
    ]

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        guard intersection > 0 else { return 0 }
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }
}

/// The plain-value shape `TriageContextBuilder` needs from a candidate
/// neighbour. Callers (the router, `NeighbourTriage`, the app's create path)
/// build this from `KTask` — kept separate from `KTask` itself so this file
/// never imports SwiftData or touches `@MainActor`.
public struct TriageExampleSource: Sendable {
    public let title: String
    public let projectName: String?
    public let priority: KPriority
    public let effort: KEffort
    public let depth: KDepth
    public let dueDay: Int?
    public let open: Bool
    public let recency: Double

    public init(title: String, projectName: String?, priority: KPriority, effort: KEffort,
                depth: KDepth, dueDay: Int?, open: Bool, recency: Double) {
        self.title = title
        self.projectName = projectName
        self.priority = priority
        self.effort = effort
        self.depth = depth
        self.dueDay = dueDay
        self.open = open
        self.recency = recency
    }
}
