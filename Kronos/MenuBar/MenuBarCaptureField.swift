// Kronos/MenuBar/MenuBarCaptureField.swift
// CAPTURE — a compact multi-line field always available in the menu bar, for capturing
// notes (e.g. from a meeting) in one keystroke without leaving the current app. "Find
// tasks" hands the typed/pasted text to the main window's existing Capture review via
// `model.openCapture(with:)` (the
// UIContract seam that landed on main) rather than duplicating its parsing.
import SwiftUI
import AppKit
import KronosCore

struct MenuBarCaptureField: View {
    @Binding var text: String
    let isFocused: FocusState<MenuBarFocusField?>.Binding
    let onFindTasks: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: "capture.title"))
                .font(Typo.caption)
                .tracking(Tracking.caption)
                .textCase(.uppercase)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize()
            KTextArea(String(localized: "menubar.capture.placeholder"), text: $text, minHeight: 48)
                .focused(isFocused, equals: .capture)
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "menubar.capture.find"), action: onFindTasks)
                    .kButton(.secondary, size: .compact)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// The two fields the popover's Tab cycles between (brief: "Tab cycles sections") — the
/// complete control and the other buttons are plain focusable controls already reachable
/// by Tab; this enum only names the two TEXT entry points so a single `@FocusState` can
/// address either one (the capture field, opened via the meeting-capture hotkey; a future
/// search-style field would extend this, not replace it).
enum MenuBarFocusField: Hashable {
    case capture
}

/// Opens Capture with the text prefilled and brings the main window forward. A free
/// function (not a method on a controller this leaf doesn't own) since both
/// `PopoverContent` and a future hotkey handler call it identically.
@MainActor
func requestCapturePrefill(model: AppModel, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    model.openCapture(with: trimmed)
    NSApp.activate(ignoringOtherApps: true)
    for window in NSApp.windows where window.isVisible == false { window.makeKeyAndOrderFront(nil) }
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
}
