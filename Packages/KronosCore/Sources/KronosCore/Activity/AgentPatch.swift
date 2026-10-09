// A change to one task as a small JSON patch: what `propose_update` carries and what an
// approval applies. Also the field snapshot the log keeps so an agent's edit can be reverted.

import Foundation

public enum AgentPatch {
    /// Keys a patch may carry.
    public static let keys: Set<String> = [
        "title", "due", "plannedDay", "priority", "project", "firstMove", "estimateMinutes",
        "dread", "effort", "energyKind", "labelsAdd", "notesAppend",
    ]

    /// The first problem with a patch (unknown key, bad type or value), or nil.
    @MainActor
    public static func problem(_ patch: [String: AgentJSON], store: any TaskStoring) -> String? {
        if patch.isEmpty { return "patch is empty" }
        let unknown = Set(patch.keys).subtracting(keys).sorted()
        if !unknown.isEmpty { return "unknown patch key \(unknown.joined(separator: ", ")); accepted: \(keys.sorted().joined(separator: ", "))" }
        for (k, v) in patch {
            switch k {
            case "title":
                guard let s = v.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count <= 500 else { return "title must be 1-500 characters" }
            case "due", "plannedDay":
                if case .null = v { continue }
                guard let s = v.string, Day.parseISO(s) != nil else { return "\(k) must be yyyy-MM-dd or null" }
            case "priority":
                guard let s = v.string, MCPPriorityName.value(s) != nil else { return "priority must be none, low, medium, high or urgent" }
            case "project":
                if case .null = v { continue }
                guard let s = v.string, project(named: s, store: store) != nil else { return "no project matching \(v.string ?? "")" }
            case "firstMove":
                if case .null = v { continue }
                guard let s = v.string, s.count <= 100 else { return "firstMove must be at most 100 characters" }
            case "estimateMinutes":
                if case .null = v { continue }
                guard let n = v.int, (1...480).contains(n) else { return "estimateMinutes must be 1-480 or null" }
            case "dread":
                guard v.bool != nil else { return "dread must be true or false" }
            case "effort":
                guard let s = v.string, MCPPriorityName.effort(s) != nil else { return "effort must be none, xs, s, m, l or xl" }
            case "energyKind":
                if case .null = v { continue }
                guard let s = v.string, MCPPriorityName.energy(s) != nil else { return "energyKind must be deepWork, admin, creative, people or physical" }
            case "labelsAdd":
                guard let a = v.array, a.count <= 10, a.allSatisfy({ $0.string != nil }) else { return "labelsAdd must be at most 10 strings" }
            case "notesAppend":
                guard let s = v.string, s.count <= 20_000 else { return "notesAppend must be at most 20000 characters" }
            default: break
            }
        }
        return nil
    }

    @MainActor
    static func project(named raw: String, store: any TaskStoring) -> KProject? {
        let all = store.allProjects()
        if let id = UUID(uuidString: raw) { return all.first { $0.id == id } }
        let f = KTextFold.fold(raw)
        return all.first { KTextFold.fold($0.name) == f }
    }

    /// Applies a validated patch as the person's own change: it registers undo (callers group it).
    @MainActor
    public static func apply(_ patch: [String: AgentJSON], to id: UUID, store: any TaskStoring) {
        store.update(id) { t in
            for (k, v) in patch {
                switch k {
                case "title": if let s = v.string { t.title = s }
                case "due":
                    if case .null = v { t.dueDay = nil } else if let s = v.string, let d = Day.parseISO(s) {
                        t.dueDay = d
                        if t.originalDueDay == nil { t.originalDueDay = d }
                    }
                case "plannedDay":
                    if case .null = v { t.plannedDay = nil } else if let s = v.string { t.plannedDay = Day.parseISO(s) }
                case "priority": if let s = v.string, let p = MCPPriorityName.value(s) { t.priority = p }
                case "project":
                    if case .null = v { setProject(nil, t) }
                    else if let s = v.string, let p = project(named: s, store: store) { setProject(p, t) }
                case "firstMove":
                    if case .null = v { t.firstMove = nil } else if let s = v.string { t.firstMove = s }
                case "estimateMinutes":
                    if case .null = v { t.estimateMinutes = nil } else if let n = v.int { t.estimateMinutes = n }
                case "dread": if let b = v.bool { t.dread = b }
                case "effort": if let s = v.string, let e = MCPPriorityName.effort(s) { t.effort = e }
                case "energyKind":
                    if case .null = v { t.energyKind = nil } else if let s = v.string { t.energyKind = MCPPriorityName.energy(s) }
                case "labelsAdd":
                    var labels = t.labels ?? []
                    for name in (v.array ?? []).compactMap(\.string) {
                        let l = store.label(named: name)
                        if !labels.contains(where: { $0.id == l.id }) { labels.append(l) }
                    }
                    t.labels = labels
                case "notesAppend":
                    if let s = v.string { t.notes = t.notes.isEmpty ? s : t.notes + "\n" + s }
                default: break
                }
            }
        }
    }

    @MainActor
    static func setProject(_ p: KProject?, _ t: KTask) {
        t.project = p
        t.projectID = p?.id
        t.areaID = p?.area?.id
        t.isProjectArchived = p?.isArchived ?? false
    }
}

/// Wire names of the store enums, without depending on the MCP layer.
enum MCPPriorityName {
    static func value(_ s: String) -> KPriority? {
        switch s { case "none": return KPriority.none; case "low": return .low; case "medium": return .medium
        case "high": return .high; case "urgent": return .urgent; default: return nil }
    }
    static func effort(_ s: String) -> KEffort? {
        switch s { case "none": return KEffort.none; case "xs": return .xs; case "s": return .s; case "m": return .m
        case "l": return .l; case "xl": return .xl; default: return nil }
    }
    static func energy(_ s: String) -> KEnergyKind? {
        switch s { case "deepWork": return .deepWork; case "admin": return .admin; case "creative": return .creative
        case "people": return .people; case "physical": return .physical; default: return nil }
    }
}

/// The fields of a task an agent edit can change, kept in the log to revert it.
public struct TaskSnapshot: Equatable, Sendable {
    public var values: [String: AgentJSON]

    @MainActor
    public init(_ t: KTask) {
        var v: [String: AgentJSON] = [
            "title": .string(t.title), "notes": .string(t.notes),
            "status": .number(Double(t.status.rawValue)), "priority": .number(Double(t.priority.rawValue)),
            "dueDay": t.dueDay.map { .number(Double($0)) } ?? .null,
            "plannedDay": t.plannedDay.map { .number(Double($0)) } ?? .null,
            "firstMove": t.firstMove.map(AgentJSON.string) ?? .null,
            "projectID": t.projectID.map { .string($0.uuidString) } ?? .null,
        ]
        v["reviewRaw"] = .number(Double(t.reviewRaw))
        values = v
    }

    /// Only the keys whose value differs: (before, after).
    public static func diff(_ before: TaskSnapshot, _ after: TaskSnapshot) -> (before: [String: AgentJSON], after: [String: AgentJSON]) {
        var b: [String: AgentJSON] = [:], a: [String: AgentJSON] = [:]
        for (k, v) in after.values where before.values[k] != v {
            b[k] = before.values[k] ?? .null
            a[k] = v
        }
        return (b, a)
    }

    /// Writes one snapshot key back. The only caller (`AgentRevert.revertToday`) wraps every call
    /// in `groupedUndo`, so this uses each field's undo-registering store method (not its
    /// `…NoUndo` twin) — the whole revert then becomes one Cmd-Z step.
    @MainActor
    static func restore(_ key: String, _ value: AgentJSON, on id: UUID, store: any TaskStoring) {
        switch key {
        case "status":
            if let n = value.int, let s = KStatus(rawValue: n) { store.setStatus(id, s) }
        case "projectID":
            let p: KProject? = value.string.flatMap(UUID.init(uuidString:)).flatMap { pid in
                store.allProjects(includeArchived: true).first { $0.id == pid }
            }
            store.update(id) { AgentPatch.setProject(p, $0) }
        default:
            store.update(id) { t in
                switch key {
                case "title": if let s = value.string { t.title = s }
                case "notes": if let s = value.string { t.notes = s }
                case "priority": if let n = value.int, let p = KPriority(rawValue: n) { t.priority = p }
                case "dueDay": t.dueDay = value.int
                case "plannedDay": t.plannedDay = value.int
                case "firstMove": t.firstMove = value.string
                case "reviewRaw": if let n = value.int { t.reviewRaw = n }
                default: break
                }
            }
        }
    }
}
