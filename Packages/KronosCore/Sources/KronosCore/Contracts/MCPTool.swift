// Part of the frozen contract surface. See Contracts.swift.
//
// The MCP tool surface. MCPDispatcher implements dispatch; nothing else knows the wire
// format. One process owns the ModelContainer, so the server is an in-process NWListener on
// 127.0.0.1:47311 with a Keychain bearer token. Clients that speak stdio reach it through the
// `kronos-mcp` bridge (Tools/kronos-mcp), which forwards every request over that same
// loopback endpoint.
//
// 35 tools: the 13 alpha tools, `list_projects` and `list_areas`, `rules_delete`, the agent loop
// (whoami, propose_*, comment_task, events_*, next), the two `upnext_*` aliases of `ordo_get` /
// `ordo_set` (the queue is shown as "Up next" in the app; the old names keep working), the
// nine tools of full control (list_labels, create_label, update_label, create_project,
// update_project, create_area, update_area, delete_area, move_task), and `review_status`
// (finish-round-1 B3: read-only, the person's "reviewed" phase-gate mark). Everything past the
// read tool list_labels needs the per-agent scope `write.all`, which Settings sets and MCP never
// can. `Annotations`, the `annotations` property and `MCPToolError` live in
// MCPToolAnnotations.swift (MCP-004, split to keep every contract file under 500 lines).
// Deliberately NOT built: impuls, dayplan_propose, triage, breakdown_task, export_json,
// ordo_push, and any tool that decides a review (Accept / Reject is the person's). A client is itself
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
    // Full control (scope write.all, off by default, set per agent in Settings): the app's
    // structure and any task, as the person would edit it. list_labels only reads.
    case listLabels    = "list_labels"
    case createLabel   = "create_label"
    case updateLabel   = "update_label"
    case createProject = "create_project"
    case updateProject = "update_project"
    case createArea    = "create_area"
    case updateArea    = "update_area"
    case deleteArea    = "delete_area"
    case moveTask      = "move_task"
    // Aliases: same handler, schema and annotations as the tool they point at.
    case upnextGet     = "upnext_get"
    case upnextSet     = "upnext_set"
    // finish-round-1 B3: read-only, person-only "reviewed" phase-gate surface for agents.
    case reviewStatus  = "review_status"

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
            return "Hear what the owner did with your tasks since a cursor: finished, approved, rejected, reopened, deleted, delegated, commented, reviewed. Pass waitSeconds (0-55) to hold the call until something happens. You see only events about your own tasks, never your own writes; events are never deleted on read."
        case .eventsAck:
            return "Move your server-side events cursor forward to upTo (never back). The session-start digest continues from it."
        case .next:
            return "The next task to do: the first eligible row of the list the owner is looking at (or Today when no list is shown), with a plain reason and the task the menu bar shows. No AI. Optional energy: low, mid or high."
        case .listProjects:
            return "List projects (id, name, areaID, areaName, icon, colorHex, isArchived, open/total task counts). Optional areaID filter; archived projects only with includeArchived."
        case .listAreas:
            return "List areas (id, name, colorHex, icon) with the ids and names of the projects each holds and open task counts."
        case .listLabels:
            return "List every label (id, name, colorHex) with how many open tasks carry it."
        case .createLabel:
            return "Needs the write.all scope. Create a label, or return the existing one with that name (created: false). Names match ignoring case and accents."
        case .updateLabel:
            return "Needs the write.all scope. Rename a label or change its colour. A name another label already has is refused. A label cannot be deleted over MCP."
        case .createProject:
            return "Needs the write.all scope. Create a project, optionally inside an area (areaID), with an icon, emoji and colour."
        case .updateProject:
            return "Needs the write.all scope. Rename a project, change its icon, emoji or colour, move it to another area (areaID, null = no area) or archive / restore it (archived). A project cannot be deleted over MCP; archive it."
        case .createArea:
            return "Needs the write.all scope. Create an area."
        case .updateArea:
            return "Needs the write.all scope. Rename an area or change its colour or icon."
        case .deleteArea:
            return "Needs the write.all scope. Delete an area that holds no projects (move or archive them first). confirm must be true."
        case .moveTask:
            return "Needs the write.all scope. Move a task to a project (project, null = none), make it a subtask of another task (parentID) or a top-level task again (parentID null), or place a subtask before one of its siblings (before; omitted = last). Works on tasks the owner made too."
        case .reviewStatus:
            return "Whether and how the owner has reviewed one or more tasks: pass ids (up to 200) or project (every task in it), never both. Read-only — no tool can set this, only the owner's own UI (inspector or context menu). For each task: state (todo or done), verdict (the agent-proposal decision — none, pending, approved or rejected; distinct from the reviewed mark, which exists on any task), and reviewedAt/reviewedBy when the owner has marked it reviewed."
        }
    }

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
             .whoami, .eventsPoll, .next, .listLabels, .reviewStatus: return false
        default: return true
        }
    }
}
