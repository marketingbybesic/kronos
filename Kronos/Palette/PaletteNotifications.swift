// Kronos/Palette/PaletteNotifications.swift
// Notification names the palette needs that do not live in Kronos/App/AppNotifications.swift.
// The convention: a command that needs a notification name not yet declared elsewhere
// declares it in its own directory, for the app shell to observe.
// (`kronosToggleInspectorRequested` already exists — declared in
// Kronos/App/AppShellView.swift and reused here as-is.)
import Foundation

extension Notification.Name {
    /// ⌘/ — open the keyboard shortcuts reference. The palette's own "Keyboard shortcuts" row
    /// pushes `KeymapReferenceView` inline instead (see CommandPaletteView), so the feature
    /// works standalone; a global ⌘/ shortcut in `KronosCommands` also posts this.
    static let kronosKeymapRequested = Notification.Name("kronosKeymapRequested")
    /// object: Bool — open (true) or close (false) every subtask list in the task list.
    static let kronosExpandAllSubtasks = Notification.Name("kronosExpandAllSubtasks")
    /// "Go to Settings" / "Settings" commands post this; AppShellView observes it and opens
    /// the `Settings { }` scene.
    static let kronosSettingsRequested = Notification.Name("kronosSettingsRequested")

    // MARK: Coach commands — this file only posts these; the Capture/Detail receivers
    // elsewhere do the real work.

    /// "Pull from Notes inbox" — opens Capture over the Notes inbox folder. No userInfo.
    static let kronosPullFromNotesRequested = Notification.Name("kronosPullFromNotesRequested")
    /// "Link Apple note to selected task" — opens the note picker for `userInfo["taskID"]`.
    static let kronosLinkNoteRequested = Notification.Name("kronosLinkNoteRequested")
}
