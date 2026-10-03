// The platform half of build-6: wires the four system signals the pure
// `DayChangeCoordinator` cannot see on its own (wake, timezone change,
// calendar day change, app activation) into `checkForDayChange()`. Kept in
// its own file behind `#if canImport(AppKit)` / `#elseif canImport(UIKit)` (iOS, visionOS;
// same public API, wake = willEnterForeground) so DayChangeCoordinator itself
// stays pure Foundation and unit-testable off-main-thread-safety concerns
// aside — no AppKit type appears in its API.

#if canImport(AppKit)
import AppKit
import Foundation

/// Owns the four `NotificationCenter` observers for the lifetime of the
/// instance. Create one alongside the app's `DayChangeCoordinator` and hold
/// a strong reference to it (e.g. on the app delegate) for as long as the
/// coordinator should keep listening.
@MainActor
public final class DayChangeObservers {
    private let coordinator: DayChangeCoordinator
    private let workspaceCenter: NotificationCenter
    private let systemCenter: NotificationCenter
    private var workspaceTokens: [NSObjectProtocol] = []
    private var systemTokens: [NSObjectProtocol] = []

    public init(coordinator: DayChangeCoordinator,
                workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
                systemCenter: NotificationCenter = .default) {
        self.coordinator = coordinator
        self.workspaceCenter = workspaceCenter
        self.systemCenter = systemCenter

        let check: @Sendable (Notification) -> Void = { [weak coordinator] _ in
            Task { @MainActor in coordinator?.checkForDayChange() }
        }

        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: check))
    }

    deinit {
        for token in workspaceTokens { workspaceCenter.removeObserver(token) }
        for token in systemTokens { systemCenter.removeObserver(token) }
    }
}
#elseif canImport(UIKit) && !os(watchOS)
import UIKit
import Foundation

/// UIKit twin of the AppKit class: same API, same four signals. There is no
/// workspace wake notification on iOS or visionOS; coming back to the
/// foreground covers wake, and `workspaceCenter` is kept only so call sites
/// compile unchanged.
@MainActor
public final class DayChangeObservers {
    private let coordinator: DayChangeCoordinator
    private let workspaceCenter: NotificationCenter
    private let systemCenter: NotificationCenter
    private var workspaceTokens: [NSObjectProtocol] = []
    private var systemTokens: [NSObjectProtocol] = []

    public init(coordinator: DayChangeCoordinator,
                workspaceCenter: NotificationCenter = .default,
                systemCenter: NotificationCenter = .default) {
        self.coordinator = coordinator
        self.workspaceCenter = workspaceCenter
        self.systemCenter = systemCenter

        let check: @Sendable (Notification) -> Void = { [weak coordinator] _ in
            Task { @MainActor in coordinator?.checkForDayChange() }
        }

        workspaceTokens.append(workspaceCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: check))
    }

    deinit {
        for token in workspaceTokens { workspaceCenter.removeObserver(token) }
        for token in systemTokens { systemCenter.removeObserver(token) }
    }
}
#elseif os(watchOS)
import WatchKit
import Foundation

/// watchOS twin: no workspace or UIApplication; the app becoming active
/// again covers wake, and the two Foundation signals cover the clock.
@MainActor
public final class DayChangeObservers {
    private let coordinator: DayChangeCoordinator
    private let workspaceCenter: NotificationCenter
    private let systemCenter: NotificationCenter
    private var workspaceTokens: [NSObjectProtocol] = []
    private var systemTokens: [NSObjectProtocol] = []

    public init(coordinator: DayChangeCoordinator,
                workspaceCenter: NotificationCenter = .default,
                systemCenter: NotificationCenter = .default) {
        self.coordinator = coordinator
        self.workspaceCenter = workspaceCenter
        self.systemCenter = systemCenter

        let check: @Sendable (Notification) -> Void = { [weak coordinator] _ in
            Task { @MainActor in coordinator?.checkForDayChange() }
        }

        workspaceTokens.append(workspaceCenter.addObserver(
            forName: WKApplication.willEnterForegroundNotification, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main, using: check))
        systemTokens.append(systemCenter.addObserver(
            forName: WKApplication.didBecomeActiveNotification, object: nil, queue: .main, using: check))
    }

    deinit {
        for token in workspaceTokens { workspaceCenter.removeObserver(token) }
        for token in systemTokens { systemCenter.removeObserver(token) }
    }
}
#endif
