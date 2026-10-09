// Part of the frozen contract surface. See Contracts.swift.
//
// `add_subtask`, `toggle_subtask`, `ordo_get` and `ordo_set` params. Split
// from MCPParams.swift to keep every contract file under 500 lines (MCP-004).

import Foundation

extension MCPParams {

    public struct AddSubtask: Codable, Equatable, Sendable {
        public let taskID: UUID
        public let title: String
        /// ISO date string (yyyy-MM-dd). Parsed via Day.parseISO on the consumer side.
        public var dueDay: String?
        /// Raw priority integer (maps to KSubtask.priorityRaw).
        public var priority: Int?

        public init(taskID: UUID, title: String, dueDay: String? = nil, priority: Int? = nil) {
            self.taskID  = taskID
            self.title   = title
            self.dueDay  = dueDay
            self.priority = priority
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            taskID   = try c.decode(UUID.self, forKey: .taskID)
            title    = try c.decode(String.self, forKey: .title)
            // `due` is the spelling every other tool uses; it is an alias of `dueDay`.
            let day = try c.decodeIfPresent(String.self, forKey: .dueDay)
            let due = try c.decodeIfPresent(String.self, forKey: .due)
            if let day, let due, day != due {
                throw DecodingError.dataCorruptedError(forKey: .due, in: c,
                    debugDescription: "due and dueDay disagree; pass one of them")
            }
            dueDay = day ?? due
            // priority is 0...4, or the same name every other tool uses (none ... urgent).
            if let n = try? c.decodeIfPresent(Int.self, forKey: .priority) {
                priority = n
            } else if let name = try c.decodeIfPresent(MCPPriority.self, forKey: .priority) {
                priority = name.kPriority.rawValue
            } else {
                priority = nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case taskID, title, dueDay, priority, due
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(taskID, forKey: .taskID)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(dueDay, forKey: .dueDay)
            try c.encodeIfPresent(priority, forKey: .priority)
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
}
