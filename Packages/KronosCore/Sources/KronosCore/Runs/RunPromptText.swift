// Kronos v1.2 "agent loop": the pure prompt builder behind Kronos/Runs/RunPrompt.swift's thin
// app-layer wrapper. Everything here is a function of its `Input` — no `TaskStoring`, no
// SwiftData, no store of any kind — so the whole prompt shape is hermetically table-tested in
// KronosCore (RunPromptTextTests.swift) with no database. Agent-facing only — plain English, not
// run through Localizable.xcstrings, same carve-out as every other agent-facing payload (MCP
// tool descriptions, AgentContext's own stored prose, RunSupervisorEngine's fallback summaries).
import Foundation

public enum RunPromptText {

    /// One subtask line, already resolved and ordered by the caller.
    public struct Subtask: Sendable {
        public let title: String
        public let done: Bool
        public init(title: String, done: Bool) { self.title = title; self.done = done }
    }

    /// Everything the prompt needs, already resolved from the store by the caller
    /// (`Kronos/Runs/RunPrompt.swift`): no `TaskStoring`, no SwiftData model, so this type and
    /// `build(_:)` below stay a pure function of plain values.
    public struct Input: Sendable {
        public var taskID: UUID
        public var runID: UUID
        public var title: String
        public var firstMove: String?
        public var priority: KPriority
        public var dueDay: Int?
        public var effort: KEffort
        /// Raw task notes, including any `notes://`/`link://` encoded lines — stripped and
        /// (for `link://`) rendered separately under "Links:" the same way the pre-extraction
        /// RunPrompt.swift always did.
        public var notes: String
        public var subtasks: [Subtask]
        public var projectName: String?
        public var waitsOnTitles: [String]
        /// The person's latest verdict word, when the person is the one who left it ("The person
        /// reviewed your last run and said: …") — set whether the last decision was an
        /// accept-with-comment or a reject, same rule `MCPDispatcher+Review.feedbackNote` uses.
        public var rejectionComment: String?
        /// Every person comment across past review cycles on this task, oldest first
        /// (`AgentContext.comments` filtered to `by == "me"`); only the last 5 are rendered.
        public var ownerComments: [String]
        /// The previous run's own `summary` (set by `RunStore.finish`), when a prior run exists.
        public var previousAttemptSummary: String?

        public init(taskID: UUID, runID: UUID, title: String, firstMove: String? = nil,
                    priority: KPriority = .none, dueDay: Int? = nil, effort: KEffort = .none,
                    notes: String = "", subtasks: [Subtask] = [], projectName: String? = nil,
                    waitsOnTitles: [String] = [], rejectionComment: String? = nil,
                    ownerComments: [String] = [], previousAttemptSummary: String? = nil) {
            self.taskID = taskID
            self.runID = runID
            self.title = title
            self.firstMove = firstMove
            self.priority = priority
            self.dueDay = dueDay
            self.effort = effort
            self.notes = notes
            self.subtasks = subtasks
            self.projectName = projectName
            self.waitsOnTitles = waitsOnTitles
            self.rejectionComment = rejectionComment
            self.ownerComments = ownerComments
            self.previousAttemptSummary = previousAttemptSummary
        }
    }

    public static func build(_ input: Input) -> String {
        var blocks: [[String]] = []

        var header = ["Task: \(input.title)"]
        if let move = input.firstMove?.trimmingCharacters(in: .whitespacesAndNewlines), !move.isEmpty {
            header.append("First move: \(move)")
        }
        blocks.append(header)

        var fields: [String] = []
        if let project = input.projectName, !project.isEmpty { fields.append("Project: \(project)") }
        if input.priority != .none { fields.append("Priority: \(priorityWord(input.priority))") }
        if let due = input.dueDay { fields.append("Due: \(Day.iso(due))") }
        if input.effort != .none { fields.append("Effort: \(effortWord(input.effort))") }

        let plainNotes = strippedNotes(input.notes)
        if !plainNotes.isEmpty { fields.append("Notes: \(plainNotes)") }

        if !input.subtasks.isEmpty {
            fields.append("Subtasks:")
            for s in input.subtasks { fields.append("- [\(s.done ? "x" : " ")] \(s.title)") }
        }

        let links = ContextLink.findAll(in: input.notes)
        if !links.isEmpty {
            fields.append("Links:")
            for l in links { fields.append("- \(l.displayName) (\(l.kind.rawValue))") }
        }

        if !input.waitsOnTitles.isEmpty { fields.append("Waits on: " + input.waitsOnTitles.joined(separator: ", ")) }
        if !fields.isEmpty { blocks.append(fields) }

        if let feedback = feedbackSection(input) { blocks.append(feedback) }

        blocks.append(["You are working Kronos task \(input.taskID.uuidString) as run \(input.runID.uuidString)."])
        blocks.append(reportingContract(runID: input.runID))
        blocks.append(["Do the work — start from First move above, it IS the action, not a question. " +
                       "If something essential is missing, run_finish outcome failed with exactly what " +
                       "is missing. Never ask a question into a log nobody reads."])

        return blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    // MARK: - person feedback

    /// nil when there is nothing to tell the agent: no verdict comment, no history, no previous
    /// attempt — the whole section is then skipped rather than shown with an empty body.
    private static func feedbackSection(_ input: Input) -> [String]? {
        var lines: [String] = []
        if let comment = input.rejectionComment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            lines.append("The owner reviewed your last run and said: \(comment)")
        }
        for c in input.ownerComments.suffix(5) {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append("- \(trimmed)") }
        }
        if let summary = input.previousAttemptSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("Your last attempt: \(summary)")
        }
        guard !lines.isEmpty else { return nil }
        return ["Owner feedback:"] + lines
    }

    // MARK: - Reporting contract

    /// Shell commands, not MCP tool calls: a harness Kronos launches may already have its own
    /// MCP tools registered against a DIFFERENT Kronos instance (the real app, when this run
    /// was launched from Demo, or vice versa) — `kronos-cli` reads `KRONOS_MCP_ENDPOINT_FILE`
    /// and `KRONOS_MCP_AGENT` (both already set by `RunSupervisorEngine.launch`) so these calls
    /// land on the instance that actually holds this run.
    private static func reportingContract(runID: UUID) -> [String] {
        [
            "Report progress and finish the run with these exact shell commands — not any Kronos " +
            "MCP tools already visible in this session, which may be registered against a " +
            "DIFFERENT Kronos instance than the one that launched you. KRONOS_MCP_ENDPOINT_FILE " +
            "and KRONOS_MCP_AGENT are already set in your environment, so these commands reach " +
            "the instance that launched you:",
            "",
            "kronos-cli --agent \"$KRONOS_AGENT\" call run_update '{\"runID\":\"\(runID.uuidString)\",\"note\":\"…\"}'",
            "kronos-cli --agent \"$KRONOS_AGENT\" call run_finish " +
            "'{\"runID\":\"\(runID.uuidString)\",\"outcome\":\"done\",\"summary\":\"…\"}'",
            "",
            "Call run_update with a one-line note at each milestone and attach artifacts (files, " +
            "commits, PRs). Finish with run_finish outcome done|failed|handoff and a summary. Do " +
            "not complete the task with complete_task.",
        ]
    }

    // MARK: - Notes

    /// The task's own notes carry `notes://`/`link://` lines (NotesLinks.swift) that encode an
    /// Apple Note link and attachments; shown properly under "Links:" above instead of as their
    /// raw encoded form here.
    private static func strippedNotes(_ raw: String) -> String {
        raw.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("notes://") && !trimmed.hasPrefix("link://")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plain-English field words (agent-facing: no Localizable.xcstrings, see file header)

    private static func priorityWord(_ p: KPriority) -> String {
        switch p {
        case .none: return "none"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .urgent: return "urgent"
        }
    }

    private static func effortWord(_ e: KEffort) -> String {
        switch e {
        case .none: return "none"
        case .xs: return "xs"
        case .s: return "s"
        case .m: return "m"
        case .l: return "l"
        case .xl: return "xl"
        }
    }
}
