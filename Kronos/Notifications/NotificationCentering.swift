// Kronos/Notifications/NotificationCentering.swift
// The one seam between Kronos and the system notification center. Everything above it (planner,
// controller, settings section, live test) speaks these plain types, so a test run can swap in the
// recording center and never reach the real one. Foundation only.
import Foundation

enum NotificationAuth: Equatable {
    case notDetermined
    case denied
    case authorized
}

/// What a person can do from the notification itself.
enum BlockStartAction: Equatable {
    case done
    case notNow
    case open
}

/// One "this block is starting" notification, fully described. Equatable so a refresh can tell that
/// nothing changed and leave the center alone.
struct BlockStartRequest: Equatable {
    let id: String
    let taskID: UUID
    let eventID: String
    let title: String
    let body: String
    let fireDate: Date
}

/// One "an agent finished a task" notification, fully described.
struct AgentDoneRequest: Equatable {
    let id: String
    let taskID: UUID
    let title: String
    let body: String
}

@MainActor
protocol NotificationCentering: AnyObject {
    /// Called with the person's choice on a delivered notification.
    var onAction: ((BlockStartAction, UUID) -> Void)? { get set }
    /// Called when the person acts on (or simply taps) an agent-completion notification.
    var onReviewOpen: ((UUID) -> Void)? { get set }
    func deliver(_ request: AgentDoneRequest) async
    func authorization() async -> NotificationAuth
    /// Shows the system prompt (only ever from the Settings toggle). True when allowed.
    func requestAuthorization() async -> Bool
    func schedule(_ request: BlockStartRequest) async
    func pendingIDs() async -> [String]
    func removePending(ids: [String]) async
}

/// A center that records instead of notifying. Used by every hermetic run (live test, snapshots,
/// a store directory override) and by the tests that drive the controller by hand.
@MainActor
final class RecordingNotificationCenter: NotificationCentering {
    var onAction: ((BlockStartAction, UUID) -> Void)?
    var onReviewOpen: ((UUID) -> Void)?
    var status: NotificationAuth
    /// What the next system prompt answers.
    var grantsOnRequest: Bool
    private(set) var requestCount = 0
    private(set) var scheduled: [String: BlockStartRequest] = [:]
    private(set) var scheduleCount = 0
    private(set) var delivered: [AgentDoneRequest] = []

    init(status: NotificationAuth = .notDetermined, grantsOnRequest: Bool = true) {
        self.status = status
        self.grantsOnRequest = grantsOnRequest
    }

    func authorization() async -> NotificationAuth { status }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        if status == .notDetermined { status = grantsOnRequest ? .authorized : .denied }
        return status == .authorized
    }

    func schedule(_ request: BlockStartRequest) async {
        scheduleCount += 1
        scheduled[request.id] = request
    }

    func deliver(_ request: AgentDoneRequest) async { delivered.append(request) }

    func pendingIDs() async -> [String] { scheduled.keys.sorted() }

    func removePending(ids: [String]) async {
        for id in ids { scheduled[id] = nil }
    }

    /// Plays the person tapping an action on a delivered notification.
    func simulate(_ action: BlockStartAction, taskID: UUID) { onAction?(action, taskID) }

    /// Plays the person tapping (or acting on) a delivered agent-done notification.
    func simulateReviewOpen(taskID: UUID) { onReviewOpen?(taskID) }
}
