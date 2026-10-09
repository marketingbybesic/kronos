// Part of the frozen contract surface. See Contracts.swift.
//
// `create_task`, `update_task` and `delete_task` params. Split from
// MCPParams.swift to keep every contract file under 500 lines (MCP-004).

import Foundation

extension MCPParams {

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
        /// When true, every name in `labels` must already exist (NOT_FOUND otherwise)
        /// instead of being created on the fly. Default false keeps the old behaviour.
        public var strictLabels: Bool
        /// Natural quick-add syntax for ONE task (`Call Tom #hit list @deep work !! friday`,
        /// optionally with `>` / indented subtasks). Parsed by the same grammar as the app's
        /// entry field. Explicit fields above always win over what the text says; with `text`
        /// present `title` may be omitted (and then is the text's own title).
        public var text: String?
        /// Day the task is planned for (yyyy-MM-dd). Never touches the due day.
        public var plannedDay: String?
        public var dread: Bool?
        public var effort: MCPEffort?
        public var energyKind: MCPEnergyKind?
        /// http(s) links attached to the task.
        public var links: [String]?
        /// Caller-chosen id, unique per agent. A repeat call returns the existing task with
        /// `created: false` instead of creating a second one.
        public var externalID: String?

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
                    triage: Bool = false,
                    strictLabels: Bool = false,
                    text: String? = nil,
                    plannedDay: String? = nil,
                    dread: Bool? = nil,
                    effort: MCPEffort? = nil,
                    energyKind: MCPEnergyKind? = nil,
                    links: [String]? = nil,
                    externalID: String? = nil) {
            self.plannedDay      = plannedDay
            self.dread           = dread
            self.effort          = effort
            self.energyKind      = energyKind
            self.links           = links
            self.externalID      = externalID
            self.text            = text
            self.strictLabels    = strictLabels
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
            text            = try c.decodeIfPresent(String.self, forKey: .text)
            // `title` stays required unless `text` carries it.
            title           = text == nil ? try c.decode(String.self, forKey: .title)
                                          : (try c.decodeIfPresent(String.self, forKey: .title) ?? "")
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
            strictLabels    = try c.decodeIfPresent(Bool.self, forKey: .strictLabels) ?? false
            plannedDay      = try c.decodeIfPresent(String.self, forKey: .plannedDay)
            dread           = try c.decodeIfPresent(Bool.self, forKey: .dread)
            effort          = try c.decodeIfPresent(MCPEffort.self, forKey: .effort)
            energyKind      = try c.decodeIfPresent(MCPEnergyKind.self, forKey: .energyKind)
            links           = try c.decodeIfPresent([String].self, forKey: .links)
            externalID      = try c.decodeIfPresent(String.self, forKey: .externalID)
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
            if effort          != nil { s.insert("effort") }
            if energyKind      != nil { s.insert("energyKind") }
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
        /// w22e: ids this task waits on; [] clears, omitted leaves alone.
        public var waitsOn: [UUID]?
        /// See `CreateTask.strictLabels`.
        public var strictLabels: Bool
        /// yyyy-MM-dd; explicit null clears the plan.
        public var plannedDay: String??
        public var dread: Bool?
        public var effort: MCPEffort?
        /// Explicit null clears the energy kind.
        public var energyKind: MCPEnergyKind??
        /// http(s) links to attach. Links already attached are skipped; none is ever removed.
        public var links: [String]?
        /// Text appended to the notes after a newline; never replaces what is there.
        public var notesAppend: String?
        public var labelsAdd: [String]?
        public var labelsRemove: [String]?

        enum CodingKeys: String, CodingKey {
            case id, title, notes, firstMove, project, priority
            case status, due, labels, depth, estimateMinutes, waitsOn, strictLabels
            case plannedDay, dread, effort, energyKind, links, notesAppend, labelsAdd, labelsRemove
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
                    estimateMinutes: Int?? = nil,
                    waitsOn: [UUID]? = nil,
                    strictLabels: Bool = false,
                    plannedDay: String?? = nil,
                    dread: Bool? = nil,
                    effort: MCPEffort? = nil,
                    energyKind: MCPEnergyKind?? = nil,
                    links: [String]? = nil,
                    notesAppend: String? = nil,
                    labelsAdd: [String]? = nil,
                    labelsRemove: [String]? = nil) {
            self.plannedDay      = plannedDay
            self.dread           = dread
            self.effort          = effort
            self.energyKind      = energyKind
            self.links           = links
            self.notesAppend     = notesAppend
            self.labelsAdd       = labelsAdd
            self.labelsRemove    = labelsRemove
            self.strictLabels    = strictLabels
            self.waitsOn         = waitsOn
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
            waitsOn  = try c.decodeIfPresent([UUID].self, forKey: .waitsOn)
            strictLabels = try c.decodeIfPresent(Bool.self, forKey: .strictLabels) ?? false
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
            plannedDay = c.contains(.plannedDay)
                ? .some(try c.decodeIfPresent(String.self, forKey: .plannedDay)) : nil
            energyKind = c.contains(.energyKind)
                ? .some(try c.decodeIfPresent(MCPEnergyKind.self, forKey: .energyKind)) : nil
            dread        = try c.decodeIfPresent(Bool.self, forKey: .dread)
            effort       = try c.decodeIfPresent(MCPEffort.self, forKey: .effort)
            links        = try c.decodeIfPresent([String].self, forKey: .links)
            notesAppend  = try c.decodeIfPresent(String.self, forKey: .notesAppend)
            labelsAdd    = try c.decodeIfPresent([String].self, forKey: .labelsAdd)
            labelsRemove = try c.decodeIfPresent([String].self, forKey: .labelsRemove)
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
            try c.encodeIfPresent(waitsOn, forKey: .waitsOn)
            if strictLabels { try c.encode(strictLabels, forKey: .strictLabels) }
            if let v = firstMove      { try c.encode(v, forKey: .firstMove) }
            if let v = project         { try c.encode(v, forKey: .project) }
            if let v = due             { try c.encode(v, forKey: .due) }
            if let v = estimateMinutes { try c.encode(v, forKey: .estimateMinutes) }
            if let v = plannedDay      { try c.encode(v, forKey: .plannedDay) }
            if let v = energyKind      { try c.encode(v, forKey: .energyKind) }
            try c.encodeIfPresent(dread, forKey: .dread)
            try c.encodeIfPresent(effort, forKey: .effort)
            try c.encodeIfPresent(links, forKey: .links)
            try c.encodeIfPresent(notesAppend, forKey: .notesAppend)
            try c.encodeIfPresent(labelsAdd, forKey: .labelsAdd)
            try c.encodeIfPresent(labelsRemove, forKey: .labelsRemove)
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
}
