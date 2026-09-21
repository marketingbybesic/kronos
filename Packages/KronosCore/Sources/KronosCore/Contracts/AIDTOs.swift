// Part of the frozen contract surface. See Contracts.swift.
//
// The four DTOs the AI layer produces and the UI consumes. Neither side
// ever sees raw JSON: the AI layer decodes into these, the UI renders them.
//
// Wire format matches the JSON Schema blocks in the prompt
// files, byte for byte. Property names here ARE the wire names; where the
// schema marks a field `required`, the property is non-optional, so a reply
// missing it fails to decode instead of silently defaulting. That is the
// point: a model that drops `firstMove` must be a hop to the next candidate,
// not a task with an empty first move.

import Foundation

// MARK: - TriageResult

/// One task's classification. Produced by `triage` and `retriage`.
///
/// Required on the wire: `priority`, `depth`, `estimateMinutes`,
/// `energyKind`, `firstMove`, `labels`, `rationale`.
/// Nullable on the wire: `project`, `due`, `proposedRule` (retriage only).
public struct TriageResult: Codable, Equatable, Sendable {

    /// Wire spelling of depth. The schema permits only these two: `unknown`
    /// is a local state for untriaged rows, never something a model returns.
    public enum Depth: String, Codable, CaseIterable, Sendable {
        case shallow, deep

        public var kDepth: KDepth { self == .shallow ? .shallow : .deep }
    }

    /// Wire spelling of energy kind, matching `KEnergyKind`'s cases.
    public enum EnergyKind: String, Codable, CaseIterable, Sendable {
        case deepWork, admin, creative, people, physical

        public var kEnergyKind: KEnergyKind {
            switch self {
            case .deepWork: return .deepWork
            case .admin:    return .admin
            case .creative: return .creative
            case .people:   return .people
            case .physical: return .physical
            }
        }
    }

    /// An existing project name, or nil. The model never invents a project:
    /// a name that matches nothing leaves the task in the Inbox.
    public let project: String?
    /// 0...4, matching `KPriority`. Out of range is clamped by the validator.
    public let priority: Int
    /// ISO-8601 "yyyy-MM-dd", or nil. A date before today is dropped to nil.
    public let due: String?
    public let depth: Depth
    /// 1...480. Out of range becomes nil at validation, not at decode.
    public let estimateMinutes: Int
    public let energyKind: EnergyKind
    /// One concrete physical action, ≤100 chars, one line. Over-long rejects
    /// the whole reply; empty falls back to the §6.2 deterministic template.
    public let firstMove: String
    /// Only names from the supplied list survive; unknown labels are dropped.
    public let labels: [String]
    /// One sentence, ≤140 chars. No advice, no encouragement.
    public let rationale: String
    /// `retriage` only, and at most one. Nil when the correction was specific
    /// to this single task rather than a generalisable class of tasks.
    public let proposedRule: ProposedRule?

    /// The user's coarse sizing (`KEffort`), wire spelling. Absent on the
    /// wire and on any reply from a model that predates this field, so it
    /// decodes as nil rather than failing the whole DTO — unlike the
    /// original required keys, an older/short reply must stay usable.
    public let effort: KEffort?
    /// One short line saying WHY, e.g. "Like 3 similar Acme tasks" or a
    /// model's own rationale restated for the neighbour-vote path. Additive,
    /// ≤90 characters, no exclamation marks (coach principle 6 — every
    /// suggestion says why). Nil when the source has nothing to add beyond
    /// `rationale`.
    public let reason: String?

    /// 0 marks a deterministic result, which the queue re-triages once a
    /// provider returns. Local only — never on the wire.
    public let version: Int

    enum CodingKeys: String, CodingKey {
        case project, priority, due, depth, estimateMinutes
        case energyKind, firstMove, labels, rationale, proposedRule
        case effort, reason
    }

    public init(project: String?,
                priority: Int,
                due: String?,
                depth: Depth,
                estimateMinutes: Int,
                energyKind: EnergyKind,
                firstMove: String,
                labels: [String],
                rationale: String,
                proposedRule: ProposedRule? = nil,
                effort: KEffort? = nil,
                reason: String? = nil,
                version: Int = 1) {
        self.project         = project
        self.priority        = priority
        self.due             = due
        self.depth           = depth
        self.estimateMinutes = estimateMinutes
        self.energyKind      = energyKind
        self.firstMove       = firstMove
        self.labels          = labels
        self.rationale       = rationale
        self.proposedRule    = proposedRule
        self.effort          = effort
        self.reason          = reason.map { String($0.prefix(90)) }
        self.version         = version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Required by the schema: decode, do not decodeIfPresent. A missing
        // key must throw so the router hops instead of inventing a value.
        priority        = try c.decode(Int.self, forKey: .priority)
        depth           = try c.decode(Depth.self, forKey: .depth)
        estimateMinutes = try c.decode(Int.self, forKey: .estimateMinutes)
        energyKind      = try c.decode(EnergyKind.self, forKey: .energyKind)
        firstMove       = try c.decode(String.self, forKey: .firstMove)
        labels          = try c.decode([String].self, forKey: .labels)
        rationale       = try c.decode(String.self, forKey: .rationale)
        // Nullable by the schema: an explicit null and an absent key are both
        // "no value", because models disagree about which one they send.
        project      = try c.decodeIfPresent(String.self, forKey: .project) ?? nil
        due          = try c.decodeIfPresent(String.self, forKey: .due) ?? nil
        proposedRule = try c.decodeIfPresent(ProposedRule.self, forKey: .proposedRule) ?? nil
        // Absent entirely on any reply from before this field existed, so
        // `decodeIfPresent` — never `decode` — for both.
        let effortRaw = try c.decodeIfPresent(Int.self, forKey: .effort) ?? nil
        effort = effortRaw.flatMap(KEffort.init(rawValue:))
        let reasonRaw = try c.decodeIfPresent(String.self, forKey: .reason) ?? nil
        reason = reasonRaw.map { String($0.prefix(90)) }
        version      = 1
    }

    /// The deterministic result. `version == 0` is
    /// the marker that makes the triage queue come back to this row.
    public static func deterministic(firstMove: String,
                                     priority: Int = 0,
                                     due: String? = nil,
                                     project: String? = nil) -> TriageResult {
        TriageResult(project: project,
                     priority: priority,
                     due: due,
                     depth: .shallow,
                     estimateMinutes: 15,
                     energyKind: .admin,
                     firstMove: firstMove,
                     labels: [],
                     rationale: "",
                     proposedRule: nil,
                     effort: nil,
                     reason: nil,
                     version: 0)
    }

    /// True when this came from the deterministic path and should be
    /// re-triaged once a provider is reachable.
    public var isDeterministic: Bool { version == 0 }
}

// MARK: - ProposedRule

/// A house rule the model suggests after a correction. At most one per
/// retriage, ≤140 chars, naming a class of tasks rather than one task.
///
/// Decodes from either a bare JSON string (what the prompt schema returns)
/// or an object, so the wire form in §8.2 and a richer future form both work.
public struct ProposedRule: Codable, Equatable, Sendable {
    /// One sentence: a condition and a consequence.
    public let text: String
    /// Where the rule applies. Defaults to `.all` when the wire omits it.
    public let scope: KRuleScope

    public init(text: String, scope: KRuleScope = .all) {
        self.text  = String(text.prefix(140))
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey { case text, scope }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let s = try? single.decode(String.self) {
            self.init(text: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .text)
        let raw = try c.decodeIfPresent(Int.self, forKey: .scope)
        self.init(text: t, scope: raw.flatMap(KRuleScope.init(rawValue:)) ?? .all)
    }

    /// Encodes as the bare string the prompt schema specifies.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }

    /// The no-op guard (§4.4): a rule that restates one task, or that is
    /// empty, is never shown.
    public var isMeaningful: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 8 && !t.lowercased().hasPrefix("this task")
    }
}

// MARK: - ImpulsRanking

/// The AI's re-ranking of already-chosen Impuls candidates, plus one mentor
/// line each. Positions are 1-based indexes into the candidate list that was
/// sent; the AI refers to candidates by position only, never by title.
///
/// This may not change WHICH tasks are candidates — only their order and
/// their mentor lines — and in practice only the mentor line of the top card
/// is ever rendered, because the card is already on screen.
public struct ImpulsRanking: Codable, Equatable, Sendable {

    public struct Entry: Codable, Equatable, Sendable {
        /// 1...5, an index into the candidate list. Never repeated.
        public let position: Int
        /// ONE sentence, ≤140 chars, written to a peer. States what the task
        /// is, not what the person should feel. No encouragement, no
        /// exclamation marks, no em dashes, no second-person commands.
        public let mentorLine: String

        public init(position: Int, mentorLine: String) {
            self.position   = position
            self.mentorLine = mentorLine
        }
    }

    public let ranked: [Entry]

    public init(ranked: [Entry]) { self.ranked = ranked }

    /// Positions must be unique and inside `1...count`. A reply that repeats
    /// or invents a position is rejected whole.
    public func isValid(candidateCount: Int) -> Bool {
        guard !ranked.isEmpty, ranked.count <= candidateCount else { return false }
        let positions = ranked.map(\.position)
        guard Set(positions).count == positions.count else { return false }
        return positions.allSatisfy { $0 >= 1 && $0 <= candidateCount }
    }
}

// MARK: - OrdoResort

/// A reordering of the ORDO queue. `order` is the new sequence of 1-based
/// positions from the queue that was sent.
public struct OrdoResort: Codable, Equatable, Sendable {
    /// Must be an exact permutation of `1...N`: no additions, no omissions,
    /// no duplicates. Anything else rejects the reply and leaves the queue
    /// untouched (build-4: partial application is never allowed).
    public let order: [Int]
    /// ≤240 chars, saying only what moved and why. Exactly
    /// `"Not a queue instruction"` when the message was not an instruction.
    public let explanation: String
    /// At most one, or nil.
    public let proposedRule: ProposedRule?

    /// The exact sentinel the prompt requires for a non-instruction.
    public static let notAnInstruction = "Not a queue instruction"

    enum CodingKeys: String, CodingKey { case order, explanation, proposedRule }

    public init(order: [Int], explanation: String, proposedRule: ProposedRule? = nil) {
        self.order        = order
        self.explanation  = explanation
        self.proposedRule = proposedRule
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order        = try c.decode([Int].self, forKey: .order)
        explanation  = try c.decode(String.self, forKey: .explanation)
        proposedRule = try c.decodeIfPresent(ProposedRule.self, forKey: .proposedRule) ?? nil
    }

    /// True only for an exact permutation of `1...count`.
    ///
    /// The empty queue is handled first and explicitly: `1...0` is an invalid
    /// range that traps at runtime, so the guard must come before the range
    /// is ever formed rather than relying on `&&` short-circuit ordering.
    public func isValid(queueCount: Int) -> Bool {
        guard queueCount > 0 else { return false }
        guard order.count == queueCount else { return false }
        return Set(order) == Set(1...queueCount)
    }

    /// True when the model reported the message was not about ordering, in
    /// which case the queue is left alone and the line is shown verbatim.
    public var isNoOp: Bool { explanation == Self.notAnInstruction }

    /// The untouched-queue reply, used by the deterministic path.
    public static func unchanged(queueCount: Int) -> OrdoResort {
        OrdoResort(order: queueCount > 0 ? Array(1...queueCount) : [],
                   explanation: notAnInstruction)
    }
}
