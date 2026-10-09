// Part of the frozen contract surface. See Contracts.swift.
//
// MCPTool.jsonSchema and the shared contextSchemaFragment. Split from MCPTool.swift to keep
// every contract file under 500 lines (MCP-004).

import Foundation

extension MCPTool {

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
               "kinds":{"type":"array","items":{"type":"string","enum":["task.completed","task.approved","task.rejected","task.edited","task.commented","task.assigned","task.reopened","task.deleted","task.reviewed","task.unreviewed"]}},
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
        case .listAreas, .listLabels:
            return #"""
            {"type":"object","additionalProperties":false,"properties":{}}
            """#
        case .createLabel:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["name"],
             "properties":{"name":{"type":"string","minLength":1,"maxLength":80},
                           "colorHex":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"}}}
            """#
        case .updateLabel:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "name":{"type":"string","minLength":1,"maxLength":80},
                           "colorHex":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"}}}
            """#
        case .createProject:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["name"],
             "properties":{"name":{"type":"string","minLength":1,"maxLength":120},
                           "areaID":{"type":"string","format":"uuid"},
                           "icon":{"type":"string","maxLength":60},
                           "emoji":{"type":"string","maxLength":8},
                           "colorHex":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"}}}
            """#
        case .updateProject:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "name":{"type":"string","minLength":1,"maxLength":120},
                           "areaID":{"type":["string","null"],"format":"uuid"},
                           "icon":{"type":["string","null"],"maxLength":60},
                           "emoji":{"type":["string","null"],"maxLength":8},
                           "colorHex":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"},
                           "archived":{"type":"boolean"}}}
            """#
        case .createArea:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["name"],
             "properties":{"name":{"type":"string","minLength":1,"maxLength":120},
                           "icon":{"type":"string","maxLength":60},
                           "colorHex":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"}}}
            """#
        case .updateArea:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "name":{"type":"string","minLength":1,"maxLength":120},
                           "icon":{"type":"string","maxLength":60},
                           "colorHex":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"}}}
            """#
        case .deleteArea:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id","confirm"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "confirm":{"type":"boolean"}}}
            """#
        case .moveTask:
            return #"""
            {"type":"object","additionalProperties":false,
             "required":["id"],
             "properties":{"id":{"type":"string","format":"uuid"},
                           "project":{"type":["string","null"],"description":"Project name or id; null = no project."},
                           "parentID":{"type":["string","null"],"format":"uuid","description":"Make this a subtask of that task; null = a top-level task again."},
                           "before":{"type":"string","format":"uuid","description":"Place a subtask directly before this sibling. Omitted = last."}}}
            """#
        case .reviewStatus:
            return #"""
            {"type":"object","additionalProperties":false,
             "properties":{
               "ids":{"type":"array","items":{"type":"string","format":"uuid"},"minItems":1,"maxItems":200,"description":"Exactly one of ids or project."},
               "project":{"type":"string","format":"uuid"}}}
            """#
        }
    }

    /// Body of the `context` object schema, shared by create_task and propose_tasks.
    static let contextSchemaFragment = #"""
    "type":"object","additionalProperties":false,"description":"What the owner needs to decide in one glance.","properties":{"why":{"type":"string","maxLength":300},"source":{"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string","enum":["email","url","chat","file","repo","meeting","calendar","other"]},"ref":{"type":"string","maxLength":500},"title":{"type":"string","maxLength":200}}},"links":{"type":"array","maxItems":10,"items":{"type":"object","additionalProperties":false,"required":["url"],"properties":{"url":{"type":"string","maxLength":2000},"title":{"type":"string","maxLength":200}}}},"expectedOutcome":{"type":"string","maxLength":200},"confidence":{"type":"number","minimum":0,"maximum":1},"session":{"type":"string","maxLength":100}}
    """#
}
