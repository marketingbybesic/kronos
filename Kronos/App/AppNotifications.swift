// Kronos/App/AppNotifications.swift
// UI-only notification names posted by the app's `.commands` menu (KronosApp.swift) and
// observed elsewhere in the UI layer. These are NOT part of Kronos/Shared/UIContract.swift
// (that file is frozen); the raw string values here are the contract instead, so every
// observer must match them exactly.
import Foundation

extension Notification.Name {
    /// Posted by File > New Task (⌘N). QuickAdd observes this to open its panel.
    static let kronosNewTaskRequested = Notification.Name("kronosNewTaskRequested")
    /// Posted by Edit > Find (⌘F). The task list observes this to focus its search field.
    static let kronosFocusSearchRequested = Notification.Name("kronosFocusSearchRequested")
    /// Posted by View > View Options (⌥⌘F). The task list observes this to open its
    /// view-options popover for the current scope.
    static let kronosViewOptionsRequested = Notification.Name("kronosViewOptionsRequested")
}
