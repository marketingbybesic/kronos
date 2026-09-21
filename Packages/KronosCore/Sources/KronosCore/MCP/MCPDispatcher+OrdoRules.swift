// L4 — MCP. Subtask, ORDO and house-rule tools. Split from
// MCPDispatcher+Tools.swift to keep every file under 500 lines.

import Foundation

extension MCPDispatcher {

    // MARK: - add_subtask / toggle_subtask

    func addSubtask(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.AddSubtask.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode add_subtask arguments")
        }
        guard store.task(params.taskID) != nil else {
            return .error(.notFound, message: "no task \(params.taskID)")
        }
        guard let sub = store.addSubtaskNoUndo(params.taskID, title: params.title) else {
            return .error(.internalError, message: "subtask was not created")
        }
        let parent = store.task(params.taskID)
        struct Result: Encodable {
            let subtask: MCPSubtaskDTO
            let subtaskCount: Int
            let subtaskDoneCount: Int
        }
        let progress = parent?.subtaskProgress ?? (done: 0, total: 0)
        return .ok(Result(subtask: MCPSubtaskDTO(sub, taskID: params.taskID),
                          subtaskCount: progress.total, subtaskDoneCount: progress.done))
    }

    func toggleSubtask(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.ToggleSubtask.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode toggle_subtask arguments")
        }
        guard let (_, taskID) = findSubtask(params.id) else {
            return .error(.notFound, message: "no subtask \(params.id)")
        }
        store.toggleSubtaskNoUndo(params.id, isDone: params.isDone)
        guard let (updated, _) = findSubtask(params.id) else {
            return .error(.internalError, message: "subtask vanished during toggle")
        }
        struct Result: Encodable {
            let subtask: MCPSubtaskDTO
            let openSubtasksLeft: Int
        }
        let openLeft = store.task(taskID).map { ($0.subtasks ?? []).filter { !$0.isDone }.count } ?? 0
        return .ok(Result(subtask: MCPSubtaskDTO(updated, taskID: taskID), openSubtasksLeft: openLeft))
    }

    private func findSubtask(_ id: UUID) -> (KSubtask, UUID)? {
        for t in store.allTasks() {
            if let s = (t.subtasks ?? []).first(where: { $0.id == id }) { return (s, t.id) }
        }
        return nil
    }

    // MARK: - ordo_get / ordo_set

    func ordoGet(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.OrdoGet.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode ordo_get arguments")
        }
        var members = store.allTasks().filter { $0.isInOrdo }
        if !params.includeDone {
            members = members.filter { KStatus.closed.contains($0.status) == false }
        }
        let sorted = members.sorted(by: Ordering.ordo)
        let barTask = sorted.first { KStatus.active.contains($0.status) }
        struct Entry: Encodable {
            let position: Int
            let ordoIndex: Double
            let isBarTask: Bool
            let task: MCPTaskCompact
        }
        let entries = sorted.enumerated().map { i, t in
            Entry(position: i + 1, ordoIndex: t.ordoIndex ?? 0, isBarTask: t.id == barTask?.id,
                 task: MCPTaskCompact(t))
        }
        struct Result: Encodable {
            let ordo: [Entry]
            let count: Int
            let openCount: Int
            let barTaskID: UUID?
        }
        return .ok(Result(ordo: entries, count: sorted.count,
                          openCount: sorted.filter { KStatus.active.contains($0.status) }.count,
                          barTaskID: barTask?.id))
    }

    func ordoSet(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.OrdoSet.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode ordo_set arguments")
        }
        if let v = params.validationError {
            return .error(v, message: "pass exactly one of order or top")
        }

        if let top = params.top {
            guard let t = store.task(top) else {
                return .error(.notFound, message: "no task \(top)")
            }
            if t.status == .waiting || t.status == .someday || KStatus.closed.contains(t.status) {
                return .error(.invalidState, message: "cannot push a \(t.status) task to ordo",
                              data: ["reason": String(describing: t.status)])
            }
            store.sendToOrdoNoUndo(top, top: true)
        } else if let order = params.order {
            var unknown: [String] = []
            var invalid: [String] = []
            for id in order {
                guard let t = store.task(id) else { unknown.append(id.uuidString); continue }
                if t.status == .waiting || t.status == .someday || KStatus.closed.contains(t.status) {
                    invalid.append(id.uuidString)
                }
            }
            if !unknown.isEmpty {
                return .error(.notFound, message: "unknown ids in order", data: ["unknownIDs": unknown])
            }
            if !invalid.isEmpty {
                return .error(.invalidState, message: "order contains waiting/someday/closed tasks",
                              data: ["invalidIDs": invalid])
            }
            let currentlyInOrdo = Set(store.allTasks().filter { $0.isInOrdo }.map(\.id))
            for id in order where !currentlyInOrdo.contains(id) {
                store.sendToOrdoNoUndo(id, top: false)
            }
            for id in currentlyInOrdo where !order.contains(id) {
                store.updateNoUndo(id) { $0.ordoIndex = nil }
            }
            // Full renormalise: 1024*(i+1), byte-reproducible.
            for (i, id) in order.enumerated() {
                store.updateNoUndo(id) { $0.ordoIndex = Double(i + 1) * 1024 }
            }
        }

        return ordoGet(Data("{}".utf8))
    }

    // MARK: - rules_list / rules_add

    func rulesList(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.RulesList.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode rules_list arguments")
        }
        struct Result: Encodable { let rules: [MCPRuleDTO] }
        return .ok(Result(rules: store.allRules(includeInactive: params.includeInactive).map(MCPRuleDTO.init)))
    }

    func rulesAdd(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.RulesAdd.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode rules_add arguments")
        }
        let trimmed = params.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 160 else {
            return .error(.invalidParams, message: "text must be 8-160 characters")
        }
        let rule = store.addRule(text: trimmed, scope: params.scope.kRuleScope, source: .manual)
        struct Result: Encodable { let rule: MCPRuleDTO }
        return .ok(Result(rule: MCPRuleDTO(rule)))
    }
}
