// The "since last time" text an agent reads at session start, and the memory block each event
// carries (frontmatter markdown, plus JSON). Kronos never writes into an agent's memory: the
// agent decides what to keep.

import Foundation

public struct DigestEvent: Equatable, Sendable {
    public var seq: Int
    public var kind: String
    public var at: Date
    public var actor: String
    public var title: String
    public var taskID: UUID?
    public var note: String?
    public var outcome: String?
    public var decision: String?
    public var editedFields: [String]
    public var reason: String?
    /// The person's verdict ("accepted" or "rejected") and the word he gave with it.
    public var verdict: String?
    public var comment: String?

    public init(seq: Int, kind: String, at: Date, actor: String, title: String, taskID: UUID? = nil,
                note: String? = nil, outcome: String? = nil, decision: String? = nil,
                editedFields: [String] = [], reason: String? = nil, verdict: String? = nil, comment: String? = nil) {
        self.seq = seq; self.kind = kind; self.at = at; self.actor = actor; self.title = title
        self.taskID = taskID; self.note = note; self.outcome = outcome; self.decision = decision
        self.editedFields = editedFields; self.reason = reason; self.verdict = verdict; self.comment = comment
    }

    /// From a log row; the title falls back to the payload when the task is gone.
    public init(row: KActivity, title: String?) {
        let p = AgentHub.payload(row)
        self.init(seq: row.seq, kind: row.verb, at: row.at, actor: row.actor,
                  title: title ?? p["title"]?.string ?? "(untitled)", taskID: row.taskID,
                  note: p["note"]?.string, outcome: p["outcome"]?.string, decision: p["decision"]?.string,
                  editedFields: (p["editedFields"]?.array ?? []).compactMap(\.string), reason: p["reason"]?.string,
                  verdict: p["verdict"]?.string, comment: p["comment"]?.string)
    }
}

public enum EventDigest {

    /// Markdown for a session-start hook; nil when there is nothing to say (the hook prints nothing).
    public static func markdown(_ events: [DigestEvent]) -> String? {
        guard !events.isEmpty else { return nil }
        var out = ["Kronos: since last time, \(events.count) update\(events.count == 1 ? "" : "s") from Alex."]
        func section(_ kind: String, _ head: (Int) -> String, _ line: (DigestEvent) -> String) {
            let group = events.filter { $0.kind == kind }
            guard !group.isEmpty else { return }
            out.append("")
            out.append(head(group.count))
            out.append(contentsOf: group.map { "- " + line($0) })
        }
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : many }
        section(ActivityVerb.completed, { "Alex finished \($0) of your tasks:" }) { e in
            var s = e.title
            if e.outcome == "canceled" { s += " (canceled)" }
            if let n = e.note, !n.isEmpty { s += ". Note: \(n)" }
            if let c = e.comment, !c.isEmpty { s += ". Alex says: \(c)" }
            return s
        }
        section(ActivityVerb.approved, { "Alex approved \($0) \(plural($0, "proposal", "proposals")):" }) { e in
            e.editedFields.isEmpty ? e.title : "\(e.title) (edited: \(e.editedFields.joined(separator: ", ")))"
        }
        section(ActivityVerb.rejected, { "Alex rejected \($0) \(plural($0, "proposal", "proposals")):" }) { e in
            e.reason.map { "\(e.title) (reason: \($0))" } ?? e.title
        }
        section(ActivityVerb.reopened, { "Alex reopened \($0) \(plural($0, "task", "tasks")):" }) { e in
            e.note.map { "\(e.title). Note: \($0)" } ?? e.title
        }
        section(ActivityVerb.deleted, { "Alex deleted \($0) of your tasks:" }) { $0.title }
        section(ActivityVerb.assigned, { "Alex gave you \($0) \(plural($0, "task", "tasks")):" }) { $0.title }
        section(ActivityVerb.commented, { "\($0) new \(plural($0, "comment", "comments")):" }) { e in
            "\(e.title): \(e.note ?? "")"
        }
        return out.joined(separator: "\n")
    }

    /// The memory block of one event: markdown with frontmatter, and the same facts as JSON.
    public static func memory(for e: DigestEvent) -> (markdown: String, json: [String: AgentJSON]) {
        let day = ISO8601DateFormatter().string(from: e.at).prefix(10)
        let verb: String
        switch e.kind {
        case ActivityVerb.completed: verb = "finished"
        case ActivityVerb.approved: verb = "approved"
        case ActivityVerb.rejected: verb = "rejected"
        case ActivityVerb.reopened: verb = "reopened"
        case ActivityVerb.deleted: verb = "deleted"
        case ActivityVerb.assigned: verb = "assigned to you"
        default: verb = "commented on"
        }
        let id = (e.taskID?.uuidString ?? "event-\(e.seq)").prefix(8).lowercased()
        var body = "Alex \(verb) \"\(e.title)\" on \(day)."
        if let n = e.note, !n.isEmpty { body += " Note: \(n)" }
        if let r = e.reason, !r.isEmpty { body += " Reason: \(r)" }
        let md = "---\nname: kronos-\(id)\ndescription: Alex \(verb) \"\(e.title)\"\ntype: reference\n---\n\(body)\n"
        var json: [String: AgentJSON] = ["kind": .string(e.kind), "title": .string(e.title), "day": .string(String(day))]
        if let t = e.taskID { json["taskID"] = .string(t.uuidString) }
        if let n = e.note { json["note"] = .string(n) }
        if let r = e.reason { json["reason"] = .string(r) }
        return (md, json)
    }
}
