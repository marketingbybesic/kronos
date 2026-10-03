#if os(macOS)
// L4 — MCP. Subtask, ORDO and house-rule tools. Split from
// MCPDispatcher+Tools.swift to keep every file under 500 lines.

import Foundation

extension MCPDispatcher {

    // MARK: - add_subtask / toggle_subtask

    func addSubtask(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.AddSubtask
        do { params = try decodeParams(MCPParams.AddSubtask.self, arguments, tool: "add_subtask") } catch { return MCPToolOutcome.from(error) }
        guard let owner = store.task(params.taskID) else {
            return .error(.notFound, message: "no task \(params.taskID)")
        }
        if let tooLong = lengthError(title: params.title) { return tooLong }
        guard !owner.isSubtask else {
            return .error(.invalidParams, message: "\(params.taskID) is a subtask; a subtask cannot have subtasks")
        }
        var due: Int?
        if let raw = params.dueDay {
            guard let parsed = Day.parseISO(raw) else {
                return .error(.invalidParams, message: "dueDay is not a valid date: \(raw)")
            }
            due = parsed
        }
        var priority = KPriority.none
        if let raw = params.priority {
            guard let p = KPriority(rawValue: raw) else {
                return .error(.invalidParams, message: "priority must be 0...4, got \(raw)")
            }
            priority = p
        }
        guard let sub = store.addSubtaskNoUndo(params.taskID, title: params.title,
                                               dueDay: due, priority: priority) else {
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
        let params: MCPParams.ToggleSubtask
        do { params = try decodeParams(MCPParams.ToggleSubtask.self, arguments, tool: "toggle_subtask") } catch { return MCPToolOutcome.from(error) }
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
        let openLeft = store.task(taskID).map { $0.orderedChildren.filter { KStatus.open.contains($0.status) }.count } ?? 0
        return .ok(Result(subtask: MCPSubtaskDTO(updated, taskID: taskID), openSubtasksLeft: openLeft))
    }

    /// A live subtask and its parent's id.
    private func findSubtask(_ id: UUID) -> (KTask, UUID)? {
        guard let s = store.task(id), let pid = s.parentID else { return nil }
        return (s, pid)
    }

    // MARK: - ordo_get / ordo_set

    func ordoGet(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.OrdoGet
        do { params = try decodeParams(MCPParams.OrdoGet.self, arguments, tool: "ordo_get") } catch { return MCPToolOutcome.from(error) }
        var members = store.allTasks().filter { $0.isInOrdo }
        if !params.includeDone {
            members = members.filter { KStatus.closed.contains($0.status) == false }
        }
        let sorted = members.sorted(by: Ordering.ordo)
        let blockedIDs = store.blockedIDs(in: sorted)
        let barTask = sorted.first { KStatus.active.contains($0.status) && !blockedIDs.contains($0.id) }
        struct Entry: Encodable {
            let position: Int
            let ordoIndex: Double
            let isBarTask: Bool
            let task: MCPTaskCompact
        }
        let entries = sorted.enumerated().map { i, t in
            Entry(position: i + 1, ordoIndex: t.ordoIndex ?? 0, isBarTask: t.id == barTask?.id,
                 task: MCPTaskCompact(t, blocked: blockedIDs.contains(t.id)))
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
        let params: MCPParams.OrdoSet
        do { params = try decodeParams(MCPParams.OrdoSet.self, arguments, tool: "ordo_set") } catch { return MCPToolOutcome.from(error) }
        if let v = params.validationError {
            return .error(v, message: "pass exactly one of order or top")
        }

        if let top = params.top {
            guard let t = store.task(top) else {
                return .error(.notFound, message: "no task \(top)")
            }
            if t.isSubtask {
                return .error(.invalidState, message: "a subtask cannot be in ordo; use its parent",
                              data: ["reason": "subtask", "parentID": t.parentID?.uuidString ?? ""])
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
                if t.isSubtask || t.status == .waiting || t.status == .someday || KStatus.closed.contains(t.status) {
                    invalid.append(id.uuidString)
                }
            }
            if !unknown.isEmpty {
                return .error(.notFound, message: "unknown ids in order", data: ["unknownIDs": unknown])
            }
            if !invalid.isEmpty {
                return .error(.invalidState, message: "order contains subtasks or waiting/someday/closed tasks",
                              data: ["invalidIDs": invalid])
            }
            let currentlyInOrdo = Set(store.allTasks().filter { $0.isInOrdo }.map(\.id))
            for id in order where !currentlyInOrdo.contains(id) {
                store.sendToOrdoNoUndo(id, top: false)
            }
            for id in currentlyInOrdo where !order.contains(id) {
                store.updateNoUndo(id) { $0.ordoIndex = nil }
            }
            placeOrdoIndices(order)
        }

        return ordoGet(Data("{}".utf8))
    }

    // MARK: - rules_list / rules_add

    func rulesList(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.RulesList
        do { params = try decodeParams(MCPParams.RulesList.self, arguments, tool: "rules_list") } catch { return MCPToolOutcome.from(error) }
        struct Result: Encodable { let rules: [MCPRuleDTO] }
        return .ok(Result(rules: store.allRules(includeInactive: params.includeInactive).map(MCPRuleDTO.init)))
    }

    func rulesAdd(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.RulesAdd
        do { params = try decodeParams(MCPParams.RulesAdd.self, arguments, tool: "rules_add") } catch { return MCPToolOutcome.from(error) }
        let trimmed = params.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= 160 else {
            return .error(.invalidParams, message: "text must be 8-160 characters")
        }
        // A rule an agent proposes changes what triage and Impuls do for the person, so it waits
        // inactive (and marked as an agent's) until the person turns it on.
        // Stored inactive and marked as an agent's. An equal rule that already exists (the person's, say)
        // is returned unchanged: it is neither deactivated nor re-labelled.
        // Through the concrete store with an explicit result type: the TaskStoring convenience of the same
        // name returns an optional and, picked here, calls itself without end.
        guard let concrete = store as? TaskStore else {
            return .error(.internalError, message: "this store cannot hold house rules")
        }
        let added: (rule: KRule, inserted: Bool) = concrete.addRule(text: trimmed, scope: params.scope.kRuleScope, source: .agent, active: false)
        struct Result: Encodable { let rule: MCPRuleDTO; let created: Bool }
        return .ok(Result(rule: MCPRuleDTO(added.rule), created: added.inserted))
    }

    func rulesDelete(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.TaskID
        do { params = try decodeParams(MCPParams.TaskID.self, arguments, tool: "rules_delete") } catch { return MCPToolOutcome.from(error) }
        guard let rule = store.allRules(includeInactive: true).first(where: { $0.id == params.id }) else {
            return .error(.notFound, message: "no rule \(params.id)")
        }
        guard store.deleteRule(rule.id) else {
            return .error(.internalError, message: "this store cannot delete rules")
        }
        struct Result: Encodable { let deleted: Bool; let id: UUID }
        return .ok(Result(deleted: true, id: params.id))
    }

    /// Gives `order` its Up next positions by moving as few rows as possible: tasks whose current
    /// index already runs in increasing order (a longest increasing run) keep it, the others are
    /// placed between their kept neighbours. Only if no room is left between two neighbours is the
    /// whole queue renumbered.
    func placeOrdoIndices(_ order: [UUID]) {
        let current: [Double?] = order.map { store.task($0)?.ordoIndex }
        // Longest strictly increasing subsequence of the existing indices (n is small: O(n^2)).
        var best = [Int](repeating: 1, count: order.count), prev = [Int](repeating: -1, count: order.count)
        var top = -1
        for i in 0..<order.count {
            guard let a = current[i] else { continue }
            for j in 0..<i {
                if let b = current[j], b < a, best[j] + 1 > best[i] { best[i] = best[j] + 1; prev[i] = j }
            }
            if top < 0 || best[i] > best[top] { top = i }
        }
        var keep = Set<Int>()
        var k = top
        while k >= 0 { keep.insert(k); k = prev[k] }
        var assigned = current
        var i = 0
        var fits = true
        while i < order.count {
            if keep.contains(i) { i += 1; continue }
            var j = i
            while j < order.count, !keep.contains(j) { j += 1 }
            let lowNeighbour: Double? = i > 0 ? assigned[i - 1] : nil
            let highNeighbour: Double? = j < order.count ? assigned[j] : nil
            let count = Double(j - i)
            let low = lowNeighbour ?? ((highNeighbour ?? 0) - 1024 * (count + 1))
            let high = highNeighbour ?? (low + 1024 * (count + 1))
            let step = (high - low) / (count + 1)
            if step < 1e-6 { fits = false; break }
            for n in i..<j { assigned[n] = low + step * Double(n - i + 1) }
            i = j
        }
        if !fits {
            for (n, id) in order.enumerated() { store.updateNoUndo(id) { $0.ordoIndex = Double(n + 1) * 1024 } }
            return
        }
        for (n, id) in order.enumerated() where assigned[n] != current[n] {
            store.updateNoUndo(id) { $0.ordoIndex = assigned[n] }
        }
    }
}
#endif
