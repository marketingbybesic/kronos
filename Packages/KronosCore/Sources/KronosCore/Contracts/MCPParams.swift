// Part of the frozen contract surface. See Contracts.swift.
//
// The Codable params structs for the MCP tools, plus the wire spellings of
// the store enums. Split out of MCPTool.swift to keep every contract file
// under 500 lines; MCPTool.swift owns the cases, the schemas and the error
// codes. `MCPParams` itself is split further, same type via `extension`,
// never changing the public shape: this file (wire enums, list_tasks,
// list_projects, get_task), MCPParams+Write.swift (create/update/delete_task),
// MCPParams+Subtasks.swift (add/toggle_subtask, ordo_get/set) and
// MCPParams+Rules.swift (rules_list/add, review_status).

import Foundation

/// Wire spelling of status, shared by `update_task` and the task DTOs.
public enum MCPStatus: String, Codable, CaseIterable, Sendable {
    case todo, inProgress, waiting, someday, done, canceled

    public var kStatus: KStatus {
        switch self {
        case .todo:       return .todo
        case .inProgress: return .inProgress
        case .waiting:    return .waiting
        case .someday:    return .someday
        case .done:       return .done
        case .canceled:   return .canceled
        }
    }

    public init(_ k: KStatus) {
        switch k {
        case .todo:       self = .todo
        case .inProgress: self = .inProgress
        case .waiting:    self = .waiting
        case .someday:    self = .someday
        case .done:       self = .done
        case .canceled:   self = .canceled
        }
    }
}

/// Wire spelling of priority.
public enum MCPPriority: String, Codable, CaseIterable, Sendable {
    case none, low, medium, high, urgent

    public var kPriority: KPriority {
        switch self {
        case .none:   return .none
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        case .urgent: return .urgent
        }
    }

    public init(_ k: KPriority) {
        switch k {
        case .none:   self = .none
        case .low:    self = .low
        case .medium: self = .medium
        case .high:   self = .high
        case .urgent: self = .urgent
        }
    }
}

/// Wire spelling of depth. Unlike `TriageResult.Depth` this one admits
/// `unknown`, because a client may legitimately clear a classification.
public enum MCPDepth: String, Codable, CaseIterable, Sendable {
    case unknown, shallow, deep

    public var kDepth: KDepth {
        switch self {
        case .unknown: return .unknown
        case .shallow: return .shallow
        case .deep:    return .deep
        }
    }
}

/// Wire spelling of the energy kind (what kind of effort a task needs).
public enum MCPEnergyKind: String, Codable, CaseIterable, Sendable {
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

    public init(_ k: KEnergyKind) {
        switch k {
        case .deepWork: self = .deepWork
        case .admin:    self = .admin
        case .creative: self = .creative
        case .people:   self = .people
        case .physical: self = .physical
        }
    }
}

/// Wire spelling of the effort sizing (t-shirt sizes).
public enum MCPEffort: String, Codable, CaseIterable, Sendable {
    case none, xs, s, m, l, xl

    public var kEffort: KEffort {
        switch self {
        case .none: return .none
        case .xs:   return .xs
        case .s:    return .s
        case .m:    return .m
        case .l:    return .l
        case .xl:   return .xl
        }
    }

    public init(_ k: KEffort) {
        switch k {
        case .none: self = .none
        case .xs:   self = .xs
        case .s:    self = .s
        case .m:    self = .m
        case .l:    self = .l
        case .xl:   self = .xl
        }
    }
}

public enum MCPParams {

    public struct ListTasks: Codable, Equatable, Sendable {
        public enum View: String, Codable, CaseIterable, Sendable {
            /// `all` = no view restriction (every live task); combine with the filters below.
            case inbox, today, upcoming, anytime, someday, project, label, ordo, search, all
        }
        public enum Fields: String, Codable, CaseIterable, Sendable { case compact, full }

        public var view: View
        public var projectID: UUID?
        public var labelID: UUID?
        public var query: String?
        public var includeDone: Bool
        public var limit: Int
        public var cursor: String?
        public var fields: Fields
        /// Extra AND filters, applied on top of `view`. A `status` of done/canceled
        /// implies includeDone for that query.
        public var status: MCPStatus?
        public var areaID: UUID?
        public var priority: MCPPriority?
        public var energyKind: MCPEnergyKind?
        /// ISO dates (yyyy-MM-dd). `due` = exactly that day; `dueFrom`/`dueTo` inclusive range.
        /// A task without a due date never matches a due filter.
        public var due: String?
        public var dueFrom: String?
        public var dueTo: String?
        /// Subtasks are not rows of their own: false (default) lists top-level tasks only.
        public var includeSubtasks: Bool

        public init(view: View = .today,
                    projectID: UUID? = nil,
                    labelID: UUID? = nil,
                    query: String? = nil,
                    includeDone: Bool = false,
                    limit: Int = 50,
                    cursor: String? = nil,
                    fields: Fields = .compact,
                    status: MCPStatus? = nil,
                    areaID: UUID? = nil,
                    priority: MCPPriority? = nil,
                    energyKind: MCPEnergyKind? = nil,
                    due: String? = nil,
                    dueFrom: String? = nil,
                    dueTo: String? = nil,
                    includeSubtasks: Bool = false) {
            self.includeSubtasks = includeSubtasks
            self.view        = view
            self.projectID   = projectID
            self.labelID     = labelID
            self.query       = query
            self.includeDone = includeDone
            self.limit       = limit
            self.cursor      = cursor
            self.fields      = fields
            self.status      = status
            self.areaID      = areaID
            self.priority    = priority
            self.energyKind  = energyKind
            self.due         = due
            self.dueFrom     = dueFrom
            self.dueTo       = dueTo
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            view        = try c.decodeIfPresent(View.self, forKey: .view) ?? .today
            projectID   = try c.decodeIfPresent(UUID.self, forKey: .projectID)
            labelID     = try c.decodeIfPresent(UUID.self, forKey: .labelID)
            query       = try c.decodeIfPresent(String.self, forKey: .query)
            includeDone = try c.decodeIfPresent(Bool.self, forKey: .includeDone) ?? false
            limit       = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 50
            cursor      = try c.decodeIfPresent(String.self, forKey: .cursor)
            fields      = try c.decodeIfPresent(Fields.self, forKey: .fields) ?? .compact
            status      = try c.decodeIfPresent(MCPStatus.self, forKey: .status)
            areaID      = try c.decodeIfPresent(UUID.self, forKey: .areaID)
            priority    = try c.decodeIfPresent(MCPPriority.self, forKey: .priority)
            energyKind  = try c.decodeIfPresent(MCPEnergyKind.self, forKey: .energyKind)
            due         = try c.decodeIfPresent(String.self, forKey: .due)
            dueFrom     = try c.decodeIfPresent(String.self, forKey: .dueFrom)
            dueTo       = try c.decodeIfPresent(String.self, forKey: .dueTo)
            includeSubtasks = try c.decodeIfPresent(Bool.self, forKey: .includeSubtasks) ?? false
        }

        /// `view: .project` without a `projectID` is INVALID_PARAMS, not an
        /// empty list — an empty list would look like "this project has no
        /// tasks".
        public var validationError: MCPToolError? {
            if limit < 1 || limit > 200 { return .invalidParams }
            if view == .project && projectID == nil { return .invalidParams }
            if view == .label && labelID == nil { return .invalidParams }
            if view == .search && (query ?? "").isEmpty { return .invalidParams }
            return nil
        }
    }

    public struct ListProjects: Codable, Equatable, Sendable {
        public var areaID: UUID?
        public var includeArchived: Bool
        public init(areaID: UUID? = nil, includeArchived: Bool = false) {
            self.areaID = areaID
            self.includeArchived = includeArchived
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            areaID          = try c.decodeIfPresent(UUID.self, forKey: .areaID)
            includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? false
        }
    }

    public struct TaskID: Codable, Equatable, Sendable {
        public let id: UUID
        public init(id: UUID) { self.id = id }
    }
}
