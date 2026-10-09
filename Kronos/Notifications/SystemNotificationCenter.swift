// Kronos/Notifications/SystemNotificationCenter.swift
// The real center. This is the only file that touches the system notification API, and the
// controller builds it only when the run is not hermetic, so a test run, a snapshot or a scratch
// store can never prompt, schedule or deliver anything on the person's Mac.
import AppKit
import UserNotifications

@MainActor
final class SystemNotificationCenter: NSObject, NotificationCentering, UNUserNotificationCenterDelegate {
    var onAction: ((BlockStartAction, UUID) -> Void)?
    var onReviewOpen: ((UUID) -> Void)?

    nonisolated private static let categoryID = "kronos.blockstart"
    nonisolated private static let doneID = "kronos.action.done"
    nonisolated private static let notNowID = "kronos.action.notnow"
    nonisolated private static let openID = "kronos.action.open"
    nonisolated private static let taskKey = "taskID"
    nonisolated private static let agentDoneCategoryID = "kronos.agentdone"
    nonisolated private static let reviewActionID = "kronos.action.review"

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        let done = UNNotificationAction(identifier: Self.doneID, title: String(localized: "notify.action.done"), options: [])
        let notNow = UNNotificationAction(identifier: Self.notNowID, title: String(localized: "notify.action.notnow"), options: [])
        let open = UNNotificationAction(identifier: Self.openID, title: String(localized: "notify.action.open"),
                                        options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [done, notNow, open],
                                              intentIdentifiers: [], options: [])
        let reviewAction = UNNotificationAction(identifier: Self.reviewActionID, title: String(localized: "agents.notify.action.review"), options: [.foreground])
        let agentDone = UNNotificationCategory(identifier: Self.agentDoneCategoryID, actions: [reviewAction], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, agentDone])
    }

    func authorization() async -> NotificationAuth {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .authorized
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    func schedule(_ request: BlockStartRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = Self.categoryID
        content.userInfo = [Self.taskKey: request.taskID.uuidString]
        let seconds = max(1, request.fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
    }

    func deliver(_ request: AgentDoneRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.categoryIdentifier = Self.agentDoneCategoryID
        content.threadIdentifier = Self.agentDoneCategoryID
        content.userInfo = [Self.taskKey: request.taskID.uuidString]
        try? await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }

    func pendingIDs() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func removePending(ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo[Self.taskKey] as? String
        let actionID = response.actionIdentifier
        guard let raw, let taskID = UUID(uuidString: raw) else { return }
        if response.notification.request.content.categoryIdentifier == Self.agentDoneCategoryID {
            await MainActor.run { self.onReviewOpen?(taskID) }
            return
        }
        let action: BlockStartAction
        switch actionID {
        case Self.doneID: action = .done
        case Self.notNowID: action = .notNow
        default: action = .open
        }
        await MainActor.run { self.onAction?(action, taskID) }
    }

    /// A block starting while Kronos is frontmost still gets its banner: that is the whole point.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
