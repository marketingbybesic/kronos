// Kronos/Triage/ReviewContext.swift
//
// What an agent attached to a proposal so it can be judged in one glance: why, where it came
// from, links, what "done" means, how sure the agent is, and, for a proposed change to an
// existing task, the patch. Read from `KTask.contextJSON` and `resultJSON` with a tolerant
// parser (every key optional, wrong types ignored), so an old or partial value never blocks a
// card. Pure Foundation: a table can compile this exact file.
import Foundation

struct ReviewContext: Equatable {
    struct Link: Equatable {
        var url: String
        var title: String?
        /// What the chip says: the title, else the host, else the address.
        var label: String {
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
            return URL(string: url)?.host ?? url
        }
    }
    struct PatchLine: Equatable {
        /// The patch key as the agent sent it ("due", "priority", ...).
        var key: String
        /// The new value as text; empty when the patch clears the field.
        var value: String
    }

    var why: String?
    var sourceTitle: String?
    var sourceKind: String?
    var links: [Link] = []
    var expectedOutcome: String?
    var confidence: Double?
    var proposalID: UUID?
    var proposalTitle: String?
    /// "update" for a proposed change to another task, nil for a new task.
    var kind: String?
    var targetID: UUID?
    var patch: [PatchLine] = []
    var updateWhy: String?

    var isUpdate: Bool { kind == "update" && targetID != nil }
    /// Below half the agent itself says it is unsure; the card shows a quiet tag.
    var isUnsure: Bool { (confidence ?? 1) < 0.5 }
    /// The reason line: an update's own reason first, else the proposal's.
    var reason: String? {
        let r = (isUpdate ? (updateWhy ?? why) : why)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r?.isEmpty ?? true) ? nil : r
    }

    static let empty = ReviewContext()

    init() {}

    init(json raw: String?) {
        guard let raw, !raw.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return }
        why = object["why"] as? String
        expectedOutcome = (object["expectedOutcome"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = object["confidence"] as? Double { confidence = c }
        if let s = object["source"] as? [String: Any] {
            sourceTitle = s["title"] as? String
            sourceKind = s["kind"] as? String
        }
        links = (object["links"] as? [[String: Any]] ?? []).compactMap { l in
            guard let url = l["url"] as? String, !url.isEmpty else { return nil }
            return Link(url: url, title: l["title"] as? String)
        }
        proposalID = (object["proposalID"] as? String).flatMap(UUID.init(uuidString:))
        proposalTitle = object["proposalTitle"] as? String
        kind = object["kind"] as? String
        if let u = object["update"] as? [String: Any] {
            targetID = (u["targetID"] as? String).flatMap(UUID.init(uuidString:))
            updateWhy = u["why"] as? String
            let p = u["patch"] as? [String: Any] ?? [:]
            patch = p.keys.sorted().map { key in
                PatchLine(key: key, value: Self.text(p[key]))
            }
        }
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let a as [Any]: return a.map { text($0) }.joined(separator: ", ")
        default: return ""
        }
    }

    /// The one-line comment the person typed when sending an agent's "done" back, newest last.
    static func lastComment(_ raw: String?) -> String? {
        guard let raw, let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let comments = object["comments"] as? [[String: Any]] else { return nil }
        return comments.last?["text"] as? String
    }
}

/// The agent's own words when it reports a task as done: `resultJSON.note` and its links.
struct ReviewResult: Equatable {
    var note: String?
    var links: [ReviewContext.Link] = []
    /// Fields the person changed on the card before approving ("due", "project", ...).
    var editedFields: [String] = []
    var decision: String?
    var reason: String?

    init(json raw: String?) {
        guard let raw, !raw.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return }
        note = object["note"] as? String
        decision = object["decision"] as? String
        reason = object["reason"] as? String
        editedFields = object["editedFields"] as? [String] ?? []
        links = (object["links"] as? [[String: Any]] ?? []).compactMap { l in
            guard let url = l["url"] as? String, !url.isEmpty else { return nil }
            return ReviewContext.Link(url: url, title: l["title"] as? String)
        }
    }
}
