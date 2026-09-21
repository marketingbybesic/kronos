// Part of the frozen contract surface. See Contracts.swift.
//
// The MCP tool surface. MCPDispatcher implements dispatch; nothing else knows the wire
// format. One process owns the ModelContainer, so this is an in-process
// NWListener on 127.0.0.1:47311 with a Keychain bearer token, not a separate
// `kronos-mcp` binary.
//
// THIRTEEN tools, not a larger set once sketched for the surface. The alpha
// scope was cut deliberately, and the reasoning is worth keeping: four of the cut
// tools made Claude Code call the app so the app could call a weaker model
// (`impuls`, `triage`, `breakdown_task`, `dayplan_propose`), when the client
// is itself the stronger model. Three more (`list_areas`, `list_projects`,
// `list_labels`) were three round-trips for what `list_tasks` can carry in
// `meta`. Deferred to Alpha-2: impuls, dayplan_propose, triage,
// breakdown_task, rules_delete, export_json, ordo_push, list_areas,
// list_projects, list_labels.
//
// Every schema is `{"type":"object","additionalProperties":false}`: unknown
// input keys are REJECTED with INVALID_PARAMS rather than ignored, because
// silent ignoring is how a client thinks it set a due date that never landed.

import Foundation

// MARK: - MCPTool

/// The 13 alpha MCP tools (scope-12).
public enum MCPTool: String, CaseIterable, Codable, Sendable {
    case listTasks     = "list_tasks"
    case getTask       = "get_task"
    case createTask    = "create_task"
    case updateTask    = "update_task"
    case completeTask  = "complete_task"
    case deleteTask    = "delete_task"
    case restoreTask   = "restore_task"
    case addSubtask    = "add_subtask"
    case toggleSubtask = "toggle_subtask"
    case ordoGet       = "ordo_get"
    case ordoSet       = "ordo_set"
    case rulesList     = "rules_list"
    case rulesAdd      = "rules_add"

    /// The wire name, as it appears in `tools/list` and `tools/call`.
    public var name: String { rawValue }

    /// One-line description sent in `tools/list`.
    public var toolDescription: String {
        switch self {
        case .listTasks:
            return "List tasks with an optional filter. The response carries meta.areas, meta.projects and meta.labels so no separate lookup call is needed."
        case .getTask:
            return "Get one task in full, including notes, subtasks and triage info."
        case .createTask:
            return "Create a task. Fields set here are recorded as protected and are never overwritten by triage."
        case .updateTask:
            return "Update fields on an existing task. Omitted fields are left alone."
        case .completeTask:
            return "Mark a task done. Open subtasks are left open and reported back."
        case .deleteTask:
            return "Soft delete a task. The row is recoverable with restore_task for 30 days."
        case .restoreTask:
            return "Restore a soft-deleted task."
        case .addSubtask:
            return "Add one step to a task."
        case .toggleSubtask:
            return "Toggle one step between done and open."
        case .ordoGet:
            return "Read the ORDO queue in order. The first active row is what the Bar shows."
        case .ordoSet:
            return "Replace the ORDO order, or move one task to the top. Applied atomically or not at all."
        case .rulesList:
            return "List the active house rules used by triage and Impuls."
        case .rulesAdd:
            return "Add one house rule. A rule names a class of tasks, not a single task."
        }
    }

    /// The MCP `inputSchema` for this tool, as a JSON string literal.
    ///
    /// Kept as a literal rather than built from the Codable struct so that the
    /// wire contract is readable in one place and cannot drift silently when
    /// a property is added. `MCPToolTests.everySchemaParses` asserts each one
    /// is valid JSON with `additionalProperties: false`.
    public var jsonSchema: String {
        switch self {
        case .listTasks:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{
               "view":{"type":"string","enum":["inbox","today","upcoming","anytime","someday","project","label","ordo","search"],"default":"today"},
               "projectID":{"type":"string","format":"uuid"},
               "labelID":{"type":"string","format":"uuid"},
               "query":{"type":"string","maxLength":200},
               "includeDone":{"type":"boolean","default":false},
               "limit":{"type":"integer","minimum":1,"maximum":200,"default":50},
               "cursor":{"type":"string"},
               "fields":{"type":"string","enum":["compact","full"],"default":"compact"}}}
            """#
        case .getTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"}}}
            """#
        case .createTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["title"],
             "properties":{
               "title":{"type":"string","minLength":1,"maxLength":500},
               "notes":{"type":"string","maxLength":10000},
               "firstMove":{"type":"string","maxLength":100},
               "project":{"type":"string"},
               "priority":{"type":"string","enum":["none","low","medium","high","urgent"]},
               "due":{"type":"string","format":"date"},
               "labels":{"type":"array","items":{"type":"string"},"maxItems":10},
               "subtasks":{"type":"array","items":{"type":"string","maxLength":120},"maxItems":20},
               "depth":{"type":"string","enum":["unknown","shallow","deep"]},
               "estimateMinutes":{"type":"integer","minimum":1,"maximum":480},
               "triage":{"type":"boolean","default":false}}}
            """#
        case .updateTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{
               "id":{"type":"string","format":"uuid"},
               "title":{"type":"string","minLength":1,"maxLength":500},
               "notes":{"type":"string","maxLength":10000},
               "firstMove":{"type":["string","null"],"maxLength":100},
               "project":{"type":["string","null"]},
               "priority":{"type":"string","enum":["none","low","medium","high","urgent"]},
               "status":{"type":"string","enum":["todo","inProgress","waiting","someday","done","canceled"]},
               "due":{"type":["string","null"],"format":"date"},
               "labels":{"type":"array","items":{"type":"string"},"maxItems":10},
               "depth":{"type":"string","enum":["unknown","shallow","deep"]},
               "estimateMinutes":{"type":["integer","null"],"minimum":1,"maximum":480}}}
            """#
        case .completeTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"}}}
            """#
        case .deleteTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id","confirm"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "confirm":{"type":"boolean"}}}
            """#
        case .restoreTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"}}}
            """#
        case .addSubtask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["taskID","title"],
             "properties":{"taskID":{"type":"string","format":"uuid"},
                           "title":{"type":"string","minLength":1,"maxLength":120}}}
            """#
        case .toggleSubtask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "isDone":{"type":"boolean"}}}
            """#
        case .ordoGet:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{"includeDone":{"type":"boolean","default":false}}}
            """#
        case .ordoSet:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{
               "order":{"type":"array","items":{"type":"string","format":"uuid"}},
               "top":{"type":"string","format":"uuid"}}}
            """#
        case .rulesList:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{"includeInactive":{"type":"boolean","default":false}}}
            """#
        case .rulesAdd:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["text"],
             "properties":{"text":{"type":"string","minLength":8,"maxLength":160},
                           "scope":{"type":"string","enum":["all","triage","impuls","ordo"],"default":"all"}}}
            """#
        }
    }

    /// True when this tool writes. Read tools are safe to call speculatively;
    /// write tools go through the `…NoUndo` store variants so an MCP client
    /// cannot bury the user's own undo history under its edits (build-14).
    public var isMutating: Bool {
        switch self {
        case .listTasks, .getTask, .ordoGet, .rulesList: return false
        default: return true
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
}

