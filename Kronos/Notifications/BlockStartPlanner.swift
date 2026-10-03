// Kronos/Notifications/BlockStartPlanner.swift
// Which notifications should exist right now. Pure: blocks and their linked task in, requests out.
// The rules are the whole product decision: one quiet "Start: <first move>" at the start of a
// calendar block that has a task linked to it, and nothing else. No due dates, no past blocks,
// no project guesses. Foundation only.
import Foundation

struct BlockStartTask: Equatable {
    let id: UUID
    let title: String
    let firstMove: String?
}

struct BlockStartCandidate: Equatable {
    let eventID: String
    let blockTitle: String
    let start: Date
    /// The open task linked directly to the block, if any.
    let task: BlockStartTask?
}

enum BlockStartPlanner {
    static let idPrefix = "kronos.blockstart."
    /// Only blocks that begin within a day are scheduled; the plan is rebuilt every minute anyway.
    static let horizon: TimeInterval = 24 * 3600
    /// The system keeps at most 64 pending requests per app; a day of blocks stays far below.
    static let maxRequests = 24

    static func id(forEvent eventID: String) -> String { idPrefix + eventID }

    /// `titleFormat` turns the first move into the notification title ("Start: <move>").
    static func plan(_ candidates: [BlockStartCandidate], now: Date,
                     titleFormat: (String) -> String) -> [BlockStartRequest] {
        var seen = Set<String>()
        var result: [BlockStartRequest] = []
        for c in candidates.sorted(by: { $0.start < $1.start }) {
            guard let task = c.task,
                  c.start > now, c.start <= now.addingTimeInterval(horizon),
                  seen.insert(c.eventID).inserted else { continue }
            let move = task.firstMove?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let line = move.isEmpty ? task.title : move
            result.append(BlockStartRequest(id: id(forEvent: c.eventID), taskID: task.id, eventID: c.eventID,
                                            title: titleFormat(line), body: c.blockTitle, fireDate: c.start))
            if result.count == maxRequests { break }
        }
        return result
    }
}
