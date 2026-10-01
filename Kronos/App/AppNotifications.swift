// Kronos/App/AppNotifications.swift
// UI-only notification names posted by the app's `.commands` menu (KronosApp.swift) and
// observed elsewhere in the UI layer. These are NOT part of Kronos/Shared/UIContract.swift
// (that file is frozen); the raw string values here are the contract instead, so every
// observer must match them exactly.
import Foundation

extension Notification.Name {
    /// Posted by File > New Task (⌘N). The list's inline "New task" row observes this and
    /// takes focus (the quick-add PANEL does not: that is `kronosQuickAddPanelRequested`).
    static let kronosNewTaskRequested = Notification.Name("kronosNewTaskRequested")
    /// Posted by Edit > Find (⌘F). The task list observes this to focus its search field.
    static let kronosFocusSearchRequested = Notification.Name("kronosFocusSearchRequested")
    /// Posted by View > View Options (⌥⌘F). The task list observes this to open its
    /// view-options popover for the current scope.
    /// Opens the floating quick-add panel (QuickAddController), same as its global hotkey.
    static let kronosQuickAddPanelRequested = Notification.Name("kronosQuickAddPanelRequested")
    /// Focuses the inspector's "Add subtask" field for the selected task (InspectorStepsSection).
    static let kronosFocusAddSubtaskRequested = Notification.Name("kronosFocusAddSubtaskRequested")
    static let kronosViewOptionsRequested = Notification.Name("kronosViewOptionsRequested")
}
