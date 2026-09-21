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
}

public struct MCPSubtaskDTO: Codable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let title: String
    public let isDone: Bool
    public let sortIndex: Double
}

public struct MCPRuleDTO: Codable, Sendable {
    public let id: UUID
    public let text: String
    public let scope: MCPParams.RulesAdd.Scope
    public let isActive: Bool
    public let createdAt: Date
}

/// `meta` block carried on `list_tasks` so a client never needs a separate
/// lookup call for area/project/label names (MCPTool.listTasks doc comment).
public struct MCPListMeta: Codable, Sendable {
    public let projects: [MCPProjectRef]
    public let labels: [MCPLabelRef]
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
    init(_ t: KTask) {
        id = t.id
        title = t.title
        status = MCPStatus(t.status)
        priority = MCPPriority(t.priority)
        dueDay = t.dueDay.map(Day.iso)
        projectName = t.project?.name
    }
}

extension MCPTaskFull {
    init(_ t: KTask, today: Int) {
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
    }
}

extension MCPSubtaskDTO {
    init(_ s: KSubtask, taskID: UUID) {
        id = s.id
        self.taskID = taskID
        title = s.title
        isDone = s.isDone
        sortIndex = s.sortIndex
    }
}

extension MCPRuleDTO {
    init(_ r: KRule) {
        id = r.id
        text = r.text
        scope = MCPParams.RulesAdd.Scope(r.scope)
        isActive = r.isActive
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
