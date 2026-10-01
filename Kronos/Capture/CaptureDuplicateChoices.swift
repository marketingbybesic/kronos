// Kronos/Capture/CaptureDuplicateChoices.swift
// The two actions on a review row whose title matches an open task: "Merge tasks" folds the row
// into that task (subtasks, notes, labels and empty fields are added, nothing is overwritten) and
// "Create anyway" makes a second task. The chosen one reads primary on a quiet fill. A duplicate
// row starts ticked as a merge, so Cmd-Return never dead-ends on it; unticking skips it.
import SwiftUI
import KronosCore

struct CaptureDuplicateChoices: View {
    let row: CaptureRow
    let onChoose: (DuplicateChoice) -> Void

    var body: some View {
        HStack(spacing: Space.x1) {
            choice(String(localized: "capture.row.merge"), .merge)
                .uiTestAnchor("capture.row.merge")
            choice(String(localized: "capture.row.create_anyway"), .createAnyway)
                .uiTestAnchor("capture.row.createanyway")
        }
    }

    private func choice(_ title: String, _ value: DuplicateChoice) -> some View {
        let isChosen = row.isTicked && row.duplicateChoice == value
        return Button { onChoose(value) } label: {
            Text(title)
                .font(Typo.meta)
                .foregroundStyle(isChosen ? Tok.textPrimary : Tok.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, Space.x2)
                .frame(minHeight: Metrics.iconM)
                .background(isChosen ? Tok.controlFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
