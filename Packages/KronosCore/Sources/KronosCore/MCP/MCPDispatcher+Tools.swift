#if os(macOS)
// L4 — MCP. The dispatch() router. The 13 original tool implementations
// live in MCPDispatcher+ListGet.swift, +Create.swift, +Update.swift and
// +CompleteDelete.swift (split out to keep every file under 500 lines);
// the rest live in +FullControl.swift / +OrdoRules.swift / review_status
// wiring. Each tool decodes its frozen Contracts/MCPParams struct, calls
// TaskStoring (NoUndo for every mutator), and returns an MCPToolOutcome.

import Foundation

extension MCPDispatcher {

    func dispatch(_ tool: MCPTool, arguments: Data) -> MCPToolOutcome {
        // An alias runs its target's handler, so both names always answer the same.
        switch tool.canonical {
        case .listTasks:     return listTasks(arguments)
        case .getTask:       return getTask(arguments)
        case .createTask:    return createTask(arguments)
        case .updateTask:    return updateTask(arguments)
        case .completeTask:  return completeTask(arguments)
        case .deleteTask:    return deleteTask(arguments)
        case .restoreTask:   return restoreTask(arguments)
        case .addSubtask:    return addSubtask(arguments)
        case .toggleSubtask: return toggleSubtask(arguments)
        case .ordoGet:       return ordoGet(arguments)
        case .ordoSet:       return ordoSet(arguments)
        case .rulesList:     return rulesList(arguments)
        case .rulesAdd:      return rulesAdd(arguments)
        case .rulesDelete:   return rulesDelete(arguments)
        case .whoami:        return whoami(arguments)
        case .proposeTasks:  return proposeTasks(arguments)
        case .proposeUpdate: return proposeUpdate(arguments)
        case .commentTask:   return commentTask(arguments)
        case .eventsPoll:    return eventsPoll(arguments)
        case .eventsAck:     return eventsAck(arguments)
        case .next:          return next(arguments)
        case .upnextGet, .upnextSet:
            return .error(.internalError, message: "alias \(tool.name) was not resolved")
        case .listProjects:  return listProjects(arguments)
        case .listAreas:     return listAreas(arguments)
        case .listLabels:    return listLabels(arguments)
        case .createLabel:   return createLabel(arguments)
        case .updateLabel:   return updateLabel(arguments)
        case .createProject: return createProject(arguments)
        case .updateProject: return updateProject(arguments)
        case .createArea:    return createArea(arguments)
        case .updateArea:    return updateArea(arguments)
        case .deleteArea:    return deleteArea(arguments)
        case .moveTask:      return moveTask(arguments)
        case .reviewStatus:  return reviewStatus(arguments)
        }
    }

}
#endif
