// Part of the frozen contract surface — see Contracts.swift. Evolves additively: nothing
// declared before is renamed or removed.
//
// The DTOs for the two capture features: pasting notes into proposed TASKS, and splitting one
// task into SUBTASKS. Split into this file rather than AIDTOs.swift, which is already near the
// 500-line cap.
//
// Both `ExtractResult` and `BreakdownResult` are PROPOSALS: value types the
// UI shows in an editable preview before anything is written to the store.
// `isDeterministic` mirrors `TriageResult.isDeterministic` — true when the
// result never touched a model — but note WHY it differs in meaning here:
// triage's `version == 0` marks a row for automatic re-triage later; capture
// has no such re-visit, `isDeterministic` here is purely "was AI involved",
// shown as the UI's quiet "AI" label.

import Foundation

// MARK: - ProposedTask

/// One task proposed from a pasted line of notes. Never written to the store
/// by Core — the UI shows it as an editable, checkable row and commits
/// through `TaskStoring.createMany`.
public struct ProposedTask: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var firstMove: String?
    public var projectName: String?
    public var labelNames: [String]
    public var priority: KPriority
    public var effort: KEffort
    public var dueDay: Int?
    public var notes: String?
    /// Subtask titles the AI extract path itself proposed for this task.
    /// The deterministic path never sets this — its own subtasks come from
    /// `NoteSplitter.subtasks(in:)`,
    /// kept on the UI-local `CaptureRow` instead (a different mechanism,
    /// same reasoning `CaptureRow`'s own doc comment gives: subtasks are not
    /// part of this frozen contract type FOR THE DETERMINISTIC PATH, but the
    /// AI reply already returns them as part of one task object, so they
    /// travel with the proposal here rather than through a second keyed
    /// lookup the way `NoteSplitter.subtasks(in:)` needs one).
    public var subtasks: [String]
    /// The input line this proposal came from — for the deterministic path, the exact original
    /// pasted line; for the AI path, the original pasted line the model's outline task was
    /// matched back onto after grounding (see `AIRouter.validateExtractOutline`'s re-pointing
    /// comment). `var`, not `let`: the AI path needs to correct it once, from the model's own
    /// outline line to the matching source line, so `CaptureModel.upgrade`'s existing
    /// containment-match against the deterministic pass's rows keeps working unchanged.
    public var sourceLine: String
    /// True when the folded title matches an existing open task's folded
    /// title — the row starts pre-unchecked in the UI, never silently
    /// filtered out.
    public var isDuplicateOfOpenTask: Bool
    /// True when this proposal (or its improvement) came from the model
    /// rather than the deterministic splitter alone.
    public var isFromAI: Bool

    public init(id: UUID = UUID(),
                title: String,
                firstMove: String? = nil,
                projectName: String? = nil,
                labelNames: [String] = [],
                priority: KPriority = .none,
                effort: KEffort = .none,
                dueDay: Int? = nil,
                notes: String? = nil,
                subtasks: [String] = [],
                sourceLine: String,
                isDuplicateOfOpenTask: Bool = false,
                isFromAI: Bool = false) {
        self.id = id
        self.title = title
        self.firstMove = firstMove
        self.projectName = projectName
        self.labelNames = labelNames
        self.priority = priority
        self.effort = effort
        self.dueDay = dueDay
        self.notes = notes
        self.subtasks = subtasks
        self.sourceLine = sourceLine
        self.isDuplicateOfOpenTask = isDuplicateOfOpenTask
        self.isFromAI = isFromAI
    }
}

/// Why `ExtractResult` ended up deterministic, or (`.ai`) which model actually answered.
/// Nothing about the outcome is silent: every `ExtractResult` carries exactly one of these;
/// `CaptureModel`/`CaptureReviewList` render one line per case, never nothing.
public enum ExtractReason: Codable, Equatable, Sendable {
    /// A model answered and at least one task passed the hallucination guard.
    case ai(model: String)
    /// AI is switched off, or `AIMode == .off` — the network was never touched.
    case aiOff
    /// AI is on but no candidate is configured (empty chain / no working key).
    case noModel
    /// Every candidate failed at the transport layer (timeout, badJSON, http, …) — the
    /// associated string is `AIError.description`, never shown raw to the user, log-only.
    case transport(String)
    /// Every candidate answered with an empty or unusable reply (no `<tasks>` block found).
    case emptyAnswer
    /// At least one candidate answered and decoded, but the hallucination guard kept zero
    /// tasks from all of them combined. The associated count is how many candidates were tried.
    case allRejected(Int)
}

/// The result of extracting tasks from a pasted note dump.
public struct ExtractResult: Codable, Equatable, Sendable {
    public let tasks: [ProposedTask]
    /// Lines that were recognised as task-shaped but exceeded the 30-proposal
    /// cap. Never silently dropped — the UI shows "N more lines not shown".
    public let droppedLineCount: Int
    /// True when this came from `NoteSplitter` alone (`AIMode.off`, or every
    /// AI candidate failed / returned nothing usable).
    public let isDeterministic: Bool
    /// WHY `isDeterministic` is what it is, or which model answered when it is not.
    /// Defaults to `.aiOff` only for source compatibility with the two-arg
    /// initializer below; every real call site sets it explicitly.
    public let reason: ExtractReason

    public init(tasks: [ProposedTask], droppedLineCount: Int = 0, isDeterministic: Bool,
                reason: ExtractReason = .aiOff) {
        self.tasks = tasks
        self.droppedLineCount = droppedLineCount
        self.isDeterministic = isDeterministic
        self.reason = reason
    }
}

// MARK: - BreakdownResult

/// The result of splitting one task into subtasks. `subtasks` is always
/// 3...7 entries — the deterministic path and the AI-validated path both
/// enforce this before returning.
public struct BreakdownResult: Codable, Equatable, Sendable {
    public let subtasks: [String]
    public let firstMove: String
    public let isDeterministic: Bool

    public init(subtasks: [String], firstMove: String, isDeterministic: Bool) {
        self.subtasks = subtasks
        self.firstMove = firstMove
        self.isDeterministic = isDeterministic
    }
}

/// The wire DTO decoded from a model's breakdown reply, before it becomes a
/// `BreakdownResult`. Kept separate because the wire shape has no
/// `isDeterministic` flag — that is added by the router once validation
/// passes (the schema requires both `subtasks` and `firstMove`).
struct BreakdownWire: Decodable {
    let subtasks: [String]
    let firstMove: String

    enum CodingKeys: String, CodingKey { case subtasks, firstMove }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtasks = try c.decode([String].self, forKey: .subtasks)
        firstMove = try c.decode(String.self, forKey: .firstMove)
    }
}

// The extract prompt returns no JSON: the model answers in the app's own outline syntax,
// parsed by `NoteSplitter`/`TaskOutline`/`QuickAddParser` — see
// `AIRouter.validateExtractOutline` (AIRouter+Capture.swift). `BreakdownWire` above is
// unrelated: the breakdown feature still uses the JSON contract.
