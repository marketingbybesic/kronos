// Kronos/Detail/BreakdownRequests.swift
// "Break down" asked for from outside the inspector (the task menu, the palette, the B key): the
// caller selects the task and files a request here; the task's Steps section takes it and opens the
// proposal preview straight away, so nobody has to find the button after the inspector opens. A
// request is only honoured shortly after it is made, so one that nothing took (no inspector on
// screen) cannot open a preview minutes later.
import Foundation

@MainActor
@Observable
final class BreakdownRequests {
    static let shared = BreakdownRequests()
    private init() {}

    /// How long a request waits for an inspector to take it.
    static let lifetime: TimeInterval = 5

    private(set) var pendingTaskID: UUID?
    private var requestedAt = Date.distantPast

    func request(taskID: UUID, now: Date = Date()) {
        pendingTaskID = taskID
        requestedAt = now
    }

    /// True once, for the task a live request names; the request is consumed.
    @discardableResult
    func take(for taskID: UUID, now: Date = Date()) -> Bool {
        guard pendingTaskID == taskID else { return false }
        pendingTaskID = nil
        return now.timeIntervalSince(requestedAt) <= Self.lifetime
    }
}
