// Part of the frozen contract surface. See Contracts.swift.
//
// The Codable params structs for the 13 alpha MCP tools, plus the wire
// spellings of the store enums. Split out of MCPTool.swift to keep every
// contract file under 500 lines; MCPTool.swift owns the cases, the schemas
// and the error codes.

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

public enum MCPParams {

    public struct ListTasks: Codable, Equatable, Sendable {
        public enum View: String, Codable, CaseIterable, Sendable {
            case inbox, today, upcoming, anytime, someday, project, label, ordo, search
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

        public init(view: View = .today,
                    projectID: UUID? = nil,
                    labelID: UUID? = nil,
                    query: String? = nil,
                    includeDone: Bool = false,
                    limit: Int = 50,
                    cursor: String? = nil,
                    fields: Fields = .compact) {
            self.view        = view
            self.projectID   = projectID
            self.labelID     = labelID
            self.query       = query
            self.includeDone = includeDone
            self.limit       = limit
            self.cursor      = cursor
            self.fields      = fields
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

    public struct TaskID: Codable, Equatable, Sendable {
        public let id: UUID
        public init(id: UUID) { self.id = id }
    }

    public struct CreateTask: Codable, Equatable, Sendable {
        public let title: String
        public var notes: String?
        public var firstMove: String?
        public var project: String?
        public var priority: MCPPriority?
        public var due: String?
        public var labels: [String]?
        public var subtasks: [String]?
        public var depth: MCPDepth?
        public var estimateMinutes: Int?
        /// Defaults to FALSE. An MCP client is itself a model and writes
        /// better first moves than the app-side triage did in testing
        /// (scope-12), so the app does not re-triage behind its back.
        public var triage: Bool

        public init(title: String,
                    notes: String? = nil,
                    firstMove: String? = nil,
                    project: String? = nil,
                    priority: MCPPriority? = nil,
                    due: String? = nil,
                    labels: [String]? = nil,
                    subtasks: [String]? = nil,
                    depth: MCPDepth? = nil,
                    estimateMinutes: Int? = nil,
                    triage: Bool = false) {
            self.title           = title
            self.notes           = notes
            self.firstMove       = firstMove
            self.project         = project
            self.priority        = priority
            self.due             = due
            self.labels          = labels
            self.subtasks        = subtasks
            self.depth           = depth
            self.estimateMinutes = estimateMinutes
            self.triage          = triage
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title           = try c.decode(String.self, forKey: .title)
            notes           = try c.decodeIfPresent(String.self, forKey: .notes)
            firstMove       = try c.decodeIfPresent(String.self, forKey: .firstMove)
            project         = try c.decodeIfPresent(String.self, forKey: .project)
            priority        = try c.decodeIfPresent(MCPPriority.self, forKey: .priority)
            due             = try c.decodeIfPresent(String.self, forKey: .due)
            labels          = try c.decodeIfPresent([String].self, forKey: .labels)
            subtasks        = try c.decodeIfPresent([String].self, forKey: .subtasks)
            depth           = try c.decodeIfPresent(MCPDepth.self, forKey: .depth)
            estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)
            triage          = try c.decodeIfPresent(Bool.self, forKey: .triage) ?? false
        }

        /// Field names the client set explicitly. Triage may never overwrite
        /// these — build-7: an explicit `"priority":"none"` is a decision,
        /// not an absent value, and the "still unset" rule alone would miss
        /// that distinction.
        public var protectedFields: Set<String> {
            var s: Set<String> = []
            if firstMove       != nil { s.insert("firstMove") }
            if project         != nil { s.insert("project") }
            if priority        != nil { s.insert("priority") }
            if due             != nil { s.insert("due") }
            if labels          != nil { s.insert("labels") }
            if depth           != nil { s.insert("depth") }
            if estimateMinutes != nil { s.insert("estimateMinutes") }
            return s
        }
    }

    /// `update_task`. Every field is optional: an omitted key means "leave
    /// alone". A field that is nullable on the wire uses a double optional so
    /// an explicit `null` ("clear this") is distinguishable from absence.
    public struct UpdateTask: Codable, Equatable, Sendable {
        public let id: UUID
        public var title: String?
        public var notes: String?
        public var firstMove: String??
        public var project: String??
        public var priority: MCPPriority?
        public var status: MCPStatus?
        public var due: String??
        public var labels: [String]?
        public var depth: MCPDepth?
        public var estimateMinutes: Int??

        enum CodingKeys: String, CodingKey {
            case id, title, notes, firstMove, project, priority
            case status, due, labels, depth, estimateMinutes
        }

        public init(id: UUID,
                    title: String? = nil,
                    notes: String? = nil,
                    firstMove: String?? = nil,
                    project: String?? = nil,
                    priority: MCPPriority? = nil,
                    status: MCPStatus? = nil,
                    due: String?? = nil,
                    labels: [String]? = nil,
                    depth: MCPDepth? = nil,
                    estimateMinutes: Int?? = nil) {
            self.id              = id
            self.title           = title
            self.notes           = notes
            self.firstMove       = firstMove
            self.project         = project
            self.priority        = priority
            self.status          = status
            self.due             = due
            self.labels          = labels
            self.depth           = depth
            self.estimateMinutes = estimateMinutes
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id       = try c.decode(UUID.self, forKey: .id)
            title    = try c.decodeIfPresent(String.self, forKey: .title)
            notes    = try c.decodeIfPresent(String.self, forKey: .notes)
            priority = try c.decodeIfPresent(MCPPriority.self, forKey: .priority)
            status   = try c.decodeIfPresent(MCPStatus.self, forKey: .status)
            labels   = try c.decodeIfPresent([String].self, forKey: .labels)
            depth    = try c.decodeIfPresent(MCPDepth.self, forKey: .depth)
            // Present-but-null must survive as .some(nil) so "clear the due
            // date" is not silently read as "do not touch the due date".
            firstMove = c.contains(.firstMove)
                ? .some(try c.decodeIfPresent(String.self, forKey: .firstMove)) : nil
            project = c.contains(.project)
                ? .some(try c.decodeIfPresent(String.self, forKey: .project)) : nil
            due = c.contains(.due)
                ? .some(try c.decodeIfPresent(String.self, forKey: .due)) : nil
            estimateMinutes = c.contains(.estimateMinutes)
                ? .some(try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)) : nil
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(notes, forKey: .notes)
            try c.encodeIfPresent(priority, forKey: .priority)
            try c.encodeIfPresent(status, forKey: .status)
            try c.encodeIfPresent(labels, forKey: .labels)
            try c.encodeIfPresent(depth, forKey: .depth)
            if let v = firstMove       { try c.encode(v, forKey: .firstMove) }
            if let v = project         { try c.encode(v, forKey: .project) }
            if let v = due             { try c.encode(v, forKey: .due) }
            if let v = estimateMinutes { try c.encode(v, forKey: .estimateMinutes) }
        }
    }

    public struct DeleteTask: Codable, Equatable, Sendable {
        public let id: UUID
        /// Required and must be true. A soft delete is recoverable, but a
        /// client that deletes by accident still loses the row from every
        /// view, so the call is explicit.
        public let confirm: Bool

        public init(id: UUID, confirm: Bool) {
            self.id = id
            self.confirm = confirm
        }

        public var validationError: MCPToolError? { confirm ? nil : .invalidParams }
    }

    public struct AddSubtask: Codable, Equatable, Sendable {
        public let taskID: UUID
        public let title: String

        public init(taskID: UUID, title: String) {
            self.taskID = taskID
            self.title  = title
        }
    }

    public struct ToggleSubtask: Codable, Equatable, Sendable {
        public let id: UUID
        /// Omitted = flip. Present = set to this value, which makes the call
        /// idempotent for a client that retries.
        public var isDone: Bool?

        public init(id: UUID, isDone: Bool? = nil) {
            self.id     = id
            self.isDone = isDone
        }
    }

    public struct OrdoGet: Codable, Equatable, Sendable {
        public var includeDone: Bool

        public init(includeDone: Bool = false) { self.includeDone = includeDone }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeDone = try c.decodeIfPresent(Bool.self, forKey: .includeDone) ?? false
        }
    }

    /// Either a full reorder (`order`) or a single push to the top (`top`),
    /// never both and never neither.
    public struct OrdoSet: Codable, Equatable, Sendable {
        public var order: [UUID]?
        public var top: UUID?

        public init(order: [UUID]? = nil, top: UUID? = nil) {
            self.order = order
            self.top   = top
        }

        /// Applied atomically or not at all (build-4): an unknown id in
        /// `order` leaves the queue byte-identical, which is why this is
        /// checked before any write rather than during one.
        public var validationError: MCPToolError? {
            switch (order, top) {
            case (nil, nil):      return .invalidParams
            case (.some, .some):  return .invalidParams
            case (.some(let o), nil):
                if o.isEmpty { return .invalidParams }
                if Set(o).count != o.count { return .invalidParams }
                return nil
            case (nil, .some):    return nil
            }
        }
    }

    public struct RulesList: Codable, Equatable, Sendable {
        public var includeInactive: Bool

        public init(includeInactive: Bool = false) { self.includeInactive = includeInactive }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includeInactive = try c.decodeIfPresent(Bool.self, forKey: .includeInactive) ?? false
        }
    }

    public struct RulesAdd: Codable, Equatable, Sendable {
        public let text: String
        public var scope: Scope

        public enum Scope: String, Codable, CaseIterable, Sendable {
            case all, triage, impuls, ordo

            public var kRuleScope: KRuleScope {
                switch self {
                case .all:    return .all
                case .triage: return .triage
                case .impuls: return .impuls
                case .ordo:   return .ordo
                }
            }
        }

        public init(text: String, scope: Scope = .all) {
            self.text  = text
            self.scope = scope
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text  = try c.decode(String.self, forKey: .text)
            scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .all
        }
    }
}
