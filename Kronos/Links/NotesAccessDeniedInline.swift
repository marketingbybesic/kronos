// Kronos/Links/NotesAccessDeniedInline.swift — split out of InspectorCoachSection.swift,
// keeping that file under the project's 500-line cap. Used by InspectorCoachSection.swift,
// Kronos/Capture/CapturePasteView.swift and Kronos/Capture/NotesPickerSheet.swift — unchanged
// behavior, just a different file.
import SwiftUI
import KronosCore

/// The one calm "Allow access" affordance every Notes-touching control shows for
/// `.notAuthorised`/`.timedOut` alike — both mean the same calm state.
struct NotesAccessDeniedInline: View {
    let error: NotesError
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Space.x2) {
            Icon("info", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            Text(String(localized: "capture.notes.denied.body"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            Button(String(localized: "capture.notes.denied.action")) { openAutomationSettings() }
                .buttonStyle(.plain)
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textPrimary)
        }
    }

    private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
