// Part of the frozen contract surface. See Contracts.swift.
//
// The MCP tool surface. MCPDispatcher implements dispatch; nothing else knows the wire
// format. One process owns the ModelContainer, so the server is an in-process NWListener on
// 127.0.0.1:47311 with a Keychain bearer token. Clients that speak stdio reach it through the
// `kronos-mcp` bridge (Tools/kronos-mcp), which forwards every request over that same
// loopback endpoint.
//
// EIGHTEEN tools: the 13 alpha tools, `list_projects` and `list_areas`, `rules_delete`, and
// the two `upnext_*` aliases of `ordo_get` / `ordo_set` (the queue is shown as "Up next" in
// the app; the old names keep working). Deliberately NOT built: impuls, dayplan_propose,
// triage, breakdown_task, export_json, ordo_push, events_poll, list_labels. A client is itself
// the stronger model, so tools that made the app call a weaker model were cut; the internal notes
// marks those sections as not built.
//
// Every schema is `{"type":"object","additionalProperties":false}`: unknown input keys are
// REJECTED with INVALID_PARAMS naming the key rather than ignored, because silent ignoring
// is how a client thinks it set a due date that never landed. MCPDispatcher enforces it from
// the `properties` of these schemas, so the schema and the check cannot drift apart.

import Foundation

// MARK: - MCPTool

/// The MCP tools, including the `upnext_*` aliases.
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
    // Added after the alpha cut (read-only lookups, so a client can discover valid ids).
    case listProjects  = "list_projects"
    case listAreas     = "list_areas"
    case rulesDelete   = "rules_delete"
    // The agent loop: who am I, propose instead of write, talk back, hear back, what next.
    case whoami        = "whoami"
    case proposeTasks  = "propose_tasks"
    case proposeUpdate = "propose_update"
    case commentTask   = "comment_task"
    case eventsPoll    = "events_poll"
    case eventsAck     = "events_ack"
    case next          = "next"
    // Aliases: same handler, schema and annotations as the tool they point at.
    case upnextGet     = "upnext_get"
    case upnextSet     = "upnext_set"

    /// The wire name, as it appears in `tools/list` and `tools/call`.
    public var name: String { rawValue }

    /// The tool whose handler runs. An alias answers exactly like its target.
    public var canonical: MCPTool {
        switch self {
        case .upnextGet: return .ordoGet
        case .upnextSet: return .ordoSet
        default: return self
        }
    }

    public var isAlias: Bool { canonical != self }

    /// One-line description sent in `tools/list`.
    public var toolDescription: String {
        switch self {
        case .listTasks:
            return "List tasks with an optional filter. The response carries meta.areas, meta.projects and meta.labels so no separate lookup call is needed. A task that waits on another open task carries blocked: true. Subtasks are tasks with a parentID and are left out unless includeSubtasks is true. The today view includes tasks planned for today or earlier (plannedDay)."
        case .getTask:
            return "Get one task in full, including notes, triage info, dread, effort, links and source; children lists its subtasks as full tasks (every task tool works on a subtask by its id)."
        case .createTask:
            return "Create a task. Fields set here are recorded as protected and are never overwritten by triage. Pass externalID (unique per agent) to make a retry safe: a repeat call returns the existing task with created: false. Tasks are stamped with the calling agent in source."
        case .updateTask:
            return "Update fields on an existing task. Omitted fields are left alone. notesAppend, labelsAdd and labelsRemove change notes and labels without replacing them; links only adds."
        case .completeTask:
            return "Mark a task done. Open subtasks are left open and reported back."
        case .deleteTask:
            return "Soft delete a task. The row is recoverable with restore_task for 30 days."
        case .restoreTask:
            return "Restore a soft-deleted task."
        case .addSubtask:
            return "Add one subtask (a child task) to a top-level task, optionally with a due day (due or dueDay, yyyy-MM-dd) and a priority (0 none ... 4 urgent, or none ... urgent)."
        case .toggleSubtask:
            return "Toggle one subtask between done and open (same as complete_task / update_task status on its id)."
        case .ordoGet:
            return "Read the ORDO queue in order. The first active row is what the Bar shows."
        case .ordoSet:
            return "Replace the ORDO order, or move one task to the top. Applied atomically or not at all."
        case .upnextGet:
            return "Read the Up next queue in order (alias of ordo_get, same result). The first active row is what the Bar shows."
        case .upnextSet:
            return "Replace the Up next order, or move one task to the top (alias of ordo_set, same result). Applied atomically or not at all."
        case .rulesList:
            return "List house rules used by Sort and Pick one. Rules added through MCP start inactive until the owner approves them."
        case .rulesAdd:
            return "Propose one house rule. A rule names a class of tasks, not a single task. It is stored inactive and has no effect until the owner turns it on."
        case .rulesDelete:
            return "Delete one house rule by id (see rules_list with includeInactive)."
        case .whoami:
            return "Who you are to Kronos: your agent slug, scopes, limits, pending proposals and your events cursor. Cheap; call it first."
        case .proposeTasks:
            return "Propose a plan as ONE review card: up to 20 tasks (each may carry subtasks and context). Nothing appears in Today, Up next or the menu bar until the owner approves. Atomic: one bad item creates nothing. Refused with REVIEW_BACKLOG while too many proposals wait."
        case .proposeUpdate:
            return "Propose a change to a task you do not own. The task stays untouched until the owner approves; the patch accepts title, due, plannedDay, priority, project, firstMove, estimateMinutes, dread, effort, energyKind, labelsAdd and notesAppend."
        case .commentTask:
            return "Add one line (at most 280 characters) to a task. The owner sees it in the inspector. Allowed on any task."
        case .eventsPoll:
            return "Hear what the owner did with your tasks since a cursor: finished, approved, rejected, reopened, deleted, delegated, commented. Pass waitSeconds (0-55) to hold the call until something happens. You see only events about your own tasks, never your own writes; events are never deleted on read."
        case .eventsAck:
            return "Move your server-side events cursor forward to upTo (never back). The session-start digest continues from it."
        case .next:
            return "The next task to do: the first eligible row of the list the owner is looking at (or Today when no list is shown), with a plain reason and the task the menu bar shows. No AI. Optional energy: low, mid or high."
        case .listProjects:
            return "List projects (id, name, areaID, areaName, icon, colorHex, isArchived, open/total task counts). Optional areaID filter; archived projects only with includeArchived."
        case .listAreas:
            return "List areas (id, name, colorHex, icon) with the ids and names of the projects each holds and open task counts."
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
               "view":{"type":"string","enum":["inbox","today","upcoming","anytime","someday","project","label","ordo","search","all"],"default":"today"},
               "status":{"type":"string","enum":["todo","inProgress","waiting","someday","done","canceled"]},
               "areaID":{"type":"string","format":"uuid"},
               "priority":{"type":"string","enum":["none","low","medium","high","urgent"]},
               "energyKind":{"type":"string","enum":["deepWork","admin","creative","people","physical"]},
               "due":{"type":"string","format":"date"},
               "dueFrom":{"type":"string","format":"date"},
               "dueTo":{"type":"string","format":"date"},
               "projectID":{"type":"string","format":"uuid"},
               "labelID":{"type":"string","format":"uuid"},
               "query":{"type":"string","maxLength":200},
               "includeDone":{"type":"boolean","default":false},
               "includeSubtasks":{"type":"boolean","default":false},
               "limit":{"type":"integer","minimum":1,"maximum":200,"default":50},
               "cursor":{"type":"string"},
               "updatedSince":{"type":"string","format":"date-time","description":"Only tasks changed at or after this ISO-8601 time."},
               "completedSince":{"type":"string","format":"date-time","description":"Only tasks completed at or after this time (implies includeDone)."},
               "owner":{"type":"string","description":"me, agent, any, or an agent slug."},
               "review":{"type":"string","enum":["pending","approved","rejected","awaitingCheck"]},
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
             "anyOf":[{"required":["title"]},{"required":["text"]}],
             "properties":{
               "title":{"type":"string","minLength":1,"maxLength":500},
               "text":{"type":"string","maxLength":2000,"description":"Quick-add syntax for one task: #project or #area (multi-word names work), @label, !/!!/!!! priority, *// effort, dates (friday, tomorrow, 5. 10.), and 'a > b' or indented lines for subtasks. Explicit fields win over the text."},
               "notes":{"type":"string","maxLength":20000},
               "firstMove":{"type":"string","maxLength":100},
               "project":{"type":"string"},
               "priority":{"type":"string","enum":["none","low","medium","high","urgent"]},
               "due":{"type":"string","format":"date"},
               "plannedDay":{"type":"string","format":"date","description":"Day to work on it. Never changes the due day."},
               "labels":{"type":"array","items":{"type":"string"},"maxItems":10},
               "subtasks":{"type":"array","items":{"type":"string","maxLength":120},"maxItems":20},
               "depth":{"type":"string","enum":["unknown","shallow","deep"]},
               "estimateMinutes":{"type":"integer","minimum":1,"maximum":480},
               "dread":{"type":"boolean","description":"The owner avoids this task; pair it with a small firstMove."},
               "effort":{"type":"string","enum":["none","xs","s","m","l","xl"]},
               "energyKind":{"type":"string","enum":["deepWork","admin","creative","people","physical"]},
               "links":{"type":"array","items":{"type":"string","maxLength":2000},"maxItems":20,"description":"http or https URLs."},
               "externalID":{"type":"string","minLength":1,"maxLength":200,"description":"Your own id for this task, unique per agent. A repeat call returns the existing task with created: false."},
               "triage":{"type":"boolean","default":false},
               "context":{\#(Self.contextSchemaFragment)},
               "assignee":{"type":"string","enum":["me","self"],"default":"me","description":"self: you will do it; completing it then comes back to the owner as done, awaiting a check."},
               "strictLabels":{"type":"boolean","default":false}}}
            """#
        case .updateTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{
               "id":{"type":"string","format":"uuid"},
               "title":{"type":"string","minLength":1,"maxLength":500},
               "notes":{"type":"string","maxLength":20000},
               "notesAppend":{"type":"string","maxLength":20000,"description":"Appended to the notes after a newline."},
               "firstMove":{"type":["string","null"],"maxLength":100},
               "project":{"type":["string","null"]},
               "priority":{"type":"string","enum":["none","low","medium","high","urgent"]},
               "status":{"type":"string","enum":["todo","inProgress","waiting","someday","done","canceled"]},
               "due":{"type":["string","null"],"format":"date"},
               "plannedDay":{"type":["string","null"],"format":"date"},
               "labels":{"type":"array","items":{"type":"string"},"maxItems":10},
               "labelsAdd":{"type":"array","items":{"type":"string"},"maxItems":10},
               "labelsRemove":{"type":"array","items":{"type":"string"},"maxItems":10},
               "depth":{"type":"string","enum":["unknown","shallow","deep"]},
               "estimateMinutes":{"type":["integer","null"],"minimum":1,"maximum":480},
               "dread":{"type":"boolean"},
               "effort":{"type":"string","enum":["none","xs","s","m","l","xl"]},
               "energyKind":{"type":["string","null"],"enum":["deepWork","admin","creative","people","physical",null]},
               "links":{"type":"array","items":{"type":"string","maxLength":2000},"maxItems":20,"description":"http or https URLs to attach. Existing links are kept."},
               "waitsOn":{"type":"array","items":{"type":"string","format":"uuid"},"maxItems":20},
               "strictLabels":{"type":"boolean","default":false}}}
            """#
        case .completeTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "result":{"type":"object","additionalProperties":false,"description":"For a task assigned to you: what you did.","properties":{
                             "note":{"type":"string","maxLength":280},
                             "links":{"type":"array","maxItems":10,"items":{"type":"object","additionalProperties":false,"required":["url"],"properties":{"url":{"type":"string","maxLength":2000},"title":{"type":"string","maxLength":200}}}}}}}}
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
                           "title":{"type":"string","minLength":1,"maxLength":120},
                           "dueDay":{"type":"string","pattern":"^\\d{4}-\\d{2}-\\d{2}$"},
                           "due":{"type":"string","pattern":"^\\d{4}-\\d{2}-\\d{2}$","description":"Alias of dueDay."},
                           "priority":{"oneOf":[{"type":"integer","minimum":0,"maximum":4},
                                                {"type":"string","enum":["none","low","medium","high","urgent"]}]}}}
            """#
        case .toggleSubtask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "isDone":{"type":"boolean"}}}
            """#
        case .ordoGet, .upnextGet:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{"includeDone":{"type":"boolean","default":false}}}
            """#
        case .ordoSet, .upnextSet:
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
        case .rulesDelete:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"}}}
            """#
        case .whoami:
            return #"""
            {"type":"object","additionalProperties":false,"properties":{}}
            """#
        case .proposeTasks:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["title","tasks"],
             "properties":{
               "title":{"type":"string","minLength":1,"maxLength":200,"description":"Names the whole proposal on the review card."},
               "context":{\#(Self.contextSchemaFragment)},
               "tasks":{"type":"array","minItems":1,"maxItems":20,"items":{"type":"object","additionalProperties":false,"required":["title"],
                 "properties":{
                   "title":{"type":"string","minLength":1,"maxLength":500},
                   "due":{"type":"string","format":"date"},
                   "plannedDay":{"type":"string","format":"date"},
                   "priority":{"type":"string","enum":["none","low","medium","high","urgent"]},
                   "project":{"type":"string"},
                   "subtasks":{"type":"array","items":{"type":"string","maxLength":120},"maxItems":20},
                   "context":{\#(Self.contextSchemaFragment)}}}}}}
            """#
        case .proposeUpdate:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id","patch"],
             "properties":{
               "id":{"type":"string","format":"uuid"},
               "patch":{"type":"object","additionalProperties":false,"minProperties":1,
                 "properties":{
                   "title":{"type":"string","minLength":1,"maxLength":500},
                   "due":{"type":["string","null"],"format":"date"},
                   "plannedDay":{"type":["string","null"],"format":"date"},
                   "priority":{"type":"string","enum":["none","low","medium","high","urgent"]},
                   "project":{"type":["string","null"]},
                   "firstMove":{"type":["string","null"],"maxLength":100},
                   "estimateMinutes":{"type":["integer","null"],"minimum":1,"maximum":480},
                   "dread":{"type":"boolean"},
                   "effort":{"type":"string","enum":["none","xs","s","m","l","xl"]},
                   "energyKind":{"type":["string","null"],"enum":["deepWork","admin","creative","people","physical",null]},
                   "labelsAdd":{"type":"array","items":{"type":"string"},"maxItems":10},
                   "notesAppend":{"type":"string","maxLength":20000}}},
               "why":{"type":"string","maxLength":300}}}
            """#
        case .commentTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id","text"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "text":{"type":"string","minLength":1,"maxLength":280}}}
            """#
        case .eventsPoll:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{
               "since":{"type":"string","description":"Cursor of the last event you saw. Omitted: continue from your acked cursor."},
               "kinds":{"type":"array","items":{"type":"string","enum":["task.completed","task.approved","task.rejected","task.edited","task.commented","task.assigned","task.reopened","task.deleted"]}},
               "waitSeconds":{"type":"integer","minimum":0,"maximum":55,"default":0},
               "limit":{"type":"integer","minimum":1,"maximum":200,"default":50},
               "format":{"type":"string","enum":["json","md"],"default":"json","description":"md adds a ready-made digest text (what the session-start hook prints)."}}}
            """#
        case .eventsAck:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["upTo"],
             "properties":{"upTo":{"type":"string","description":"Highest event cursor you have handled."}}}
            """#
        case .next:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{"energy":{"type":"string","enum":["low","mid","high"]}}}
            """#
        case .listProjects:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{"areaID":{"type":"string","format":"uuid"},
                           "includeArchived":{"type":"boolean","default":false}}}
            """#
        case .listAreas:
            return #"""
            {"type":"object","additionalProperties":false,"properties":{}}
            """#
        }
    }

    /// Body of the `context` object schema, shared by create_task and propose_tasks.
    static let contextSchemaFragment = #"""
    "type":"object","additionalProperties":false,"description":"What the owner needs to decide in one glance.","properties":{"why":{"type":"string","maxLength":300},"source":{"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string","enum":["email","url","chat","file","repo","meeting","calendar","other"]},"ref":{"type":"string","maxLength":500},"title":{"type":"string","maxLength":200}}},"links":{"type":"array","maxItems":10,"items":{"type":"object","additionalProperties":false,"required":["url"],"properties":{"url":{"type":"string","maxLength":2000},"title":{"type":"string","maxLength":200}}}},"expectedOutcome":{"type":"string","maxLength":200},"confidence":{"type":"number","minimum":0,"maximum":1},"session":{"type":"string","maxLength":100}}
    """#

    /// The parameter names this tool accepts: the keys of its schema's `properties`.
    public var allowedKeys: Set<String> {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(jsonSchema.utf8)) as? [String: Any],
              let props = obj["properties"] as? [String: Any] else { return [] }
        return Set(props.keys)
    }

    /// True when this tool writes. Read tools are safe to call speculatively;
    /// write tools go through the `…NoUndo` store variants so an MCP client
    /// cannot bury the user's own undo history under its edits (build-14).
    public var isMutating: Bool {
        switch self {
        case .listTasks, .getTask, .ordoGet, .upnextGet, .rulesList, .listProjects, .listAreas,
             .whoami, .eventsPoll, .next: return false
        default: return true
        }
    }

    // MARK: - Annotations

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
