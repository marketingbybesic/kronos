#if os(macOS)
// L4 — MCP. Output shapes for the 13 alpha tools. Kept separate from the
// frozen Contracts/MCPParams.swift (input) so this leaf never edits a file it
// does not own. Encoding is stable-keyed JSON via KronosJSON-equivalent rules:
// dates ISO-8601 UTC, enums lowercase strings, nulls emitted not omitted.

import Foundation

/// One JSONEncoder/JSONDecoder configuration for the whole MCP surface:
/// ISO-8601 dates, sorted keys, unescaped slashes.
public enum MCPJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Compact task shape for `list_tasks(fields: .compact)` and every list
/// context that embeds a task by reference (ordo, subtask parent, …).
public struct MCPTaskCompact: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let status: MCPStatus
    public let priority: MCPPriority
    public let dueDay: String?
    public let projectName: String?
    /// The parent task of a subtask; absent for a top-level task.
    public let parentID: UUID?
    /// w22e: present (true) only while the task waits on an open task; absent otherwise.
    public let blocked: Bool?
}

/// Full task shape for `fields: .full`, `get_task`, and every tool that
/// hands back the task it just touched.
public struct MCPTaskFull: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let notes: String
    public let status: MCPStatus
    public let priority: MCPPriority
    public let depth: MCPDepth
    public let firstMove: String?
    public let dueDay: String?
    public let carryDays: Int
    public let estimateMinutes: Int?
    public let projectID: UUID?
    public let projectName: String?
    public let labels: [String]
    public let ordoIndex: Double?
    public let subtaskCount: Int
    public let subtaskDoneCount: Int
    public let needsTriage: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let completedAt: Date?
    public let deletedAt: Date?
    /// w22e: ids this task waits on (absent when none) and `blocked: true` while any is open.
    public let waitsOn: [UUID]?
    public let blocked: Bool?
    public let areaID: UUID?
    public let energyKind: MCPEnergyKind?
    /// The parent task of a subtask; absent for a top-level task.
    public let parentID: UUID?
    /// Day the task is planned for (yyyy-MM-dd), separate from the due day.
    public let plannedDay: String?
    public let dread: Bool
    public let effort: MCPEffort
    /// Where the task came from: `agent:<name>` or `mcp` for a task an agent wrote, nil for the app.
    public let source: String?
    /// The caller's own id for the task (see create_task `externalID`).
    public let externalID: String?
    /// http(s) links attached to the task, oldest first.
    public let links: [String]
    /// pending, approved, rejected or awaitingCheck; absent for an ordinary task.
    public let review: String?
    /// "agent" when the task is delegated to an agent; absent when the person does it.
    public let assignee: String?
    /// The agent that owns the task (see whoami); absent for the person's own tasks.
    public let agentID: UUID?
    /// What the agent attached (why, source, links, expectedOutcome, comments).
    public let context: AgentJSON?
    /// What came back when the task closed or a proposal was decided.
    public let result: AgentJSON?
}

public struct MCPProjectDTO: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let areaID: UUID?
    public let areaName: String?
    public let icon: String?
    public let emoji: String?
    public let colorHex: String
    public let isArchived: Bool
    public let sortIndex: Double
    public let openTaskCount: Int
    public let totalTaskCount: Int
}

public struct MCPAreaDTO: Codable, Sendable {
    public struct ProjectRef: Codable, Sendable {
        public let id: UUID
        public let name: String
    }
    public let id: UUID
    public let name: String
    public let colorHex: String
    public let icon: String
    public let sortIndex: Double
    public let projects: [ProjectRef]
    public let openTaskCount: Int
}

public struct MCPSubtaskDTO: Codable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let title: String
    public let isDone: Bool
    public let sortIndex: Double
    /// O15: optional due day for subtasks (additive field).
    public let dueDay: String?
    /// O15: optional priority for subtasks (additive field).
    public let priority: Int?

    /// `subtask` is a child task; `taskID` its parent.
    public init(_ subtask: KTask, taskID: UUID) {
        self.id = subtask.id
        self.taskID = taskID
        self.title = subtask.title
        self.isDone = KStatus.closed.contains(subtask.status)
        self.sortIndex = subtask.sortIndex
        self.dueDay = subtask.dueDay.map(Day.iso)
        self.priority = subtask.priorityRaw
    }
}

public struct MCPRuleDTO: Codable, Sendable {
    public let id: UUID
    public let text: String
    public let scope: MCPParams.RulesAdd.Scope
    public let isActive: Bool
    /// `manual`, `feedback`, `ordoProposal` or `agent`.
    public let source: String
    public let createdAt: Date
}

/// `meta` block carried on `list_tasks` so a client never needs a separate
/// lookup call for area/project/label names (MCPTool.listTasks doc comment).
public struct MCPListMeta: Codable, Sendable {
    public let areas: [MCPAreaRef]
    public let projects: [MCPProjectRef]
    public let labels: [MCPLabelRef]
}

public struct MCPAreaRef: Codable, Sendable {
    public let id: UUID
    public let name: String
}

public struct MCPProjectRef: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let areaName: String?
    /// rev 6 (§12.8): the project's curated Icon-map name, or nil for the
    /// plain colour dot — an unknown/unrecognised name is passed through as
    /// given rather than rejected, matching how the store itself stores it.
    public let icon: String?
}

public struct MCPLabelRef: Codable, Sendable {
    public let id: UUID
    public let name: String
}

// MARK: - Builders

extension MCPTaskCompact {
    init(_ t: KTask, blocked isBlocked: Bool = false) {
        id = t.id
        title = t.title
        status = MCPStatus(t.status)
        priority = MCPPriority(t.priority)
        dueDay = t.dueDay.map(Day.iso)
        projectName = t.project?.name
        parentID = t.parentID
        blocked = isBlocked ? true : nil
    }
}

extension MCPTaskFull {
    init(_ t: KTask, today: Int, blocked isBlocked: Bool = false) {
        id = t.id
        title = t.title
        notes = t.notes
        status = MCPStatus(t.status)
        priority = MCPPriority(t.priority)
        depth = MCPDepth(t.depth)
        firstMove = t.firstMove
        dueDay = t.dueDay.map(Day.iso)
        carryDays = t.carryDays(today: today)
        estimateMinutes = t.estimateMinutes
        projectID = t.projectID
        projectName = t.project?.name
        labels = (t.labels ?? []).map(\.name).sorted { KTextFold.fold($0) < KTextFold.fold($1) }
        ordoIndex = t.ordoIndex
        let progress = t.subtaskProgress
        subtaskCount = progress.total
        subtaskDoneCount = progress.done
        needsTriage = t.needsTriage
        createdAt = t.createdAt
        updatedAt = t.updatedAt
        completedAt = t.completedAt
        deletedAt = t.deletedAt
        waitsOn = t.waitsOnIDs.isEmpty ? nil : t.waitsOn
        blocked = isBlocked ? true : nil
        areaID = t.areaID
        energyKind = t.energyKind.map(MCPEnergyKind.init)
        parentID = t.parentID
        plannedDay = t.plannedDay.map(Day.iso)
        dread = t.dread
        effort = MCPEffort(t.effort)
        source = t.source
        externalID = t.externalID
        links = (t.attachments ?? []).filter { $0.kindRaw == 0 }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap(\.url)
        review = MCPTaskFull.reviewName(t.reviewRaw)
        assignee = t.assigneeRaw == 1 ? "agent" : nil
        agentID = t.agentID
        context = t.contextJSON.flatMap(AgentJSON.parse).map(AgentJSON.object)
        result = t.resultJSON.flatMap(AgentJSON.parse).map(AgentJSON.object)
    }

    static func reviewName(_ raw: Int) -> String? {
        switch raw {
        case 1: return "pending"
        case 2: return "approved"
        case 3: return "rejected"
        case 4: return "awaitingCheck"
        default: return nil
        }
    }
}


extension MCPRuleDTO {
    init(_ r: KRule) {
        id = r.id
        text = r.text
        scope = MCPParams.RulesAdd.Scope(r.scope)
        isActive = r.isActive
        source = KRule.sourceName(raw: r.sourceRaw)
        createdAt = r.createdAt
    }
}

extension MCPParams.RulesAdd.Scope {
    init(_ k: KRuleScope) {
        switch k {
        case .all:    self = .all
        case .triage: self = .triage
        case .impuls: self = .impuls
        case .ordo:   self = .ordo
        }
    }
}

extension MCPDepth {
    /// `MCPParams.swift` only declares `kDepth` (wire -> store). The
    /// dispatcher needs the reverse for building a response, and it is not
    /// safe to add it to the frozen contract file, so it lives here instead.
    init(_ k: KDepth) {
        switch k {
        case .unknown: self = .unknown
        case .shallow: self = .shallow
        case .deep:    self = .deep
        }
    }
}

extension KRule {
    /// Raw value of the agent origin. KRuleSource has no case for it yet; the raw column holds
    /// any Int, so the store needs no change.
    static let agentSourceRaw = KRuleSource.agent.rawValue

    static func sourceName(raw: Int) -> String {
        if raw == agentSourceRaw { return "agent" }
        switch KRuleSource(rawValue: raw) {
        case .feedback: return "feedback"
        case .ordoProposal: return "ordoProposal"
        default: return "manual"
        }
    }
}
#endif
