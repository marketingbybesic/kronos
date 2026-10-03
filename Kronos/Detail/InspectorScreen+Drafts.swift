// Kronos/Detail/InspectorScreen+Drafts.swift
// What the inspector's three text drafts show for a task, and the AI rationale panel: split out
// of InspectorScreen.swift to keep that file inside the 500-line limit.
import SwiftUI
import KronosCore

extension InspectorScreen {
    /// What the store shows for `task`, in the form the three draft fields render it.
    static func shown(_ task: KTask) -> InspectorDrafts.Shown {
        InspectorDrafts.Shown(title: task.title,
                              notes: InspectorNotesText.visible(task.notes),
                              firstMove: editableFirstMove(task))
    }

    /// The stored move as the field shows it: a generic placeholder sentence counts as empty,
    /// so the hint ("Review: <title>") shows instead; committing clears the placeholder.
    static func editableFirstMove(_ task: KTask) -> String {
        guard let move = task.firstMove, !DeterministicFirstMove.isGenericTemplate(move) else { return "" }
        return move
    }
}

/// The model's one-sentence rationale for its triage, under the notes.
struct InspectorRationalePanel: View {
    let rationale: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            InspectorSectionCaption(String(localized: "detail.rationale"))
            KPanel {
                HStack(alignment: .top, spacing: Space.x2) {
                    Icon("sparkles", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                    Text(rationale)
                        .font(Typo.body)
                        .foregroundStyle(Tok.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
