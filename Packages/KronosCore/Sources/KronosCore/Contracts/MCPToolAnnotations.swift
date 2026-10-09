// Part of the frozen contract surface. See Contracts.swift.
//
// MCPTool's `Annotations` (the MCP `annotations` object sent in `tools/list`), the per-tool
// `annotations` property and `MCPToolError`. Split from MCPTool.swift to keep every contract
// file under 500 lines (MCP-004).

import Foundation

// MARK: - Annotations

extension MCPTool {

    /// The MCP `annotations` object sent in `tools/list`. Hints, not guarantees: a client may
    /// use them to decide what to auto-approve.
    public struct Annotations: Equatable, Sendable {
        public let title: String
        public let readOnlyHint: Bool
        public let destructiveHint: Bool
        public let idempotentHint: Bool
        public let openWorldHint: Bool

        public var jsonObject: [String: Any] {
            ["title": title, "readOnlyHint": readOnlyHint, "destructiveHint": destructiveHint,
             "idempotentHint": idempotentHint, "openWorldHint": openWorldHint]
        }
    }

    /// An alias carries its target's annotations unchanged.
    public var annotations: Annotations {
        func read(_ title: String) -> Annotations {
            Annotations(title: title, readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        }
        func write(_ title: String, destructive: Bool, idempotent: Bool) -> Annotations {
            Annotations(title: title, readOnlyHint: false, destructiveHint: destructive,
                        idempotentHint: idempotent, openWorldHint: false)
        }
        switch canonical {
        case .listTasks:     return read("List tasks")
        case .getTask:       return read("Get a task")
        case .ordoGet:       return read("Read the Up next queue")
        case .rulesList:     return read("List house rules")
        case .listProjects:  return read("List projects")
        case .listAreas:     return read("List areas")
        case .listLabels:    return read("List labels")
        case .createLabel:   return write("Create a label", destructive: false, idempotent: true)
        case .updateLabel:   return write("Update a label", destructive: true, idempotent: true)
        case .createProject: return write("Create a project", destructive: false, idempotent: false)
        case .updateProject: return write("Update a project", destructive: true, idempotent: true)
        case .createArea:    return write("Create an area", destructive: false, idempotent: false)
        case .updateArea:    return write("Update an area", destructive: true, idempotent: true)
        case .deleteArea:    return write("Delete an area", destructive: true, idempotent: true)
        case .moveTask:      return write("Move a task", destructive: true, idempotent: true)
        case .createTask:    return write("Create a task", destructive: false, idempotent: false)
        case .updateTask:    return write("Update a task", destructive: true, idempotent: true)
        case .completeTask:  return write("Complete a task", destructive: false, idempotent: false)
        case .deleteTask:    return write("Delete a task", destructive: true, idempotent: true)
        case .restoreTask:   return write("Restore a task", destructive: false, idempotent: true)
        case .addSubtask:    return write("Add a subtask", destructive: false, idempotent: false)
        case .toggleSubtask: return write("Toggle a subtask", destructive: false, idempotent: false)
        case .ordoSet:       return write("Reorder the Up next queue", destructive: true, idempotent: true)
        case .rulesAdd:      return write("Propose a house rule", destructive: false, idempotent: false)
        case .rulesDelete:   return write("Delete a house rule", destructive: true, idempotent: true)
        case .whoami:        return read("Who am I")
        case .eventsPoll:    return read("Hear back from the owner")
        case .next:          return read("The next task")
        case .proposeTasks:  return write("Propose tasks for review", destructive: false, idempotent: false)
        case .proposeUpdate: return write("Propose a change to a task", destructive: false, idempotent: false)
        case .commentTask:   return write("Comment on a task", destructive: false, idempotent: false)
        case .eventsAck:     return write("Acknowledge events", destructive: false, idempotent: true)
        case .reviewStatus:  return read("Review status")
        case .upnextGet, .upnextSet: return read("")   // unreachable: canonical never returns an alias
        }
    }
}

// MARK: - Tool errors

/// Tool-level errors. These ride inside a successful JSON-RPC `result` with
/// `isError: true`, never as a `-32xxx` transport error: a task that does not
/// exist is a normal answer to a reasonable question, not a protocol fault.
public enum MCPToolError: String, Codable, CaseIterable, Sendable {
    case notFound       = "NOT_FOUND"
    case invalidParams  = "INVALID_PARAMS"
    case invalidState   = "INVALID_STATE"
    case invalidCursor  = "INVALID_CURSOR"
    case conflict       = "CONFLICT"
    case internalError  = "INTERNAL"
    /// The caller lacks the scope or does not own the task.
    case forbidden      = "FORBIDDEN"
    /// Too many unreviewed proposals; wait for events.
    case reviewBacklog  = "REVIEW_BACKLOG"
    /// Calls per minute or creates per day exceeded.
    case rateLimited    = "RATE_LIMITED"
}
