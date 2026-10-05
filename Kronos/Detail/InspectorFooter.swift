// Footer meta: created / updated (relative, localized), Linear id if externalID is set,
// and a quiet "Delete task" text button — soft delete with a 5s undo pill, wording and
// position distinguishing it from destructive actions rather than colour (no red).
import SwiftUI
import KronosCore

struct InspectorFooter: View {
    let model: AppModel
    let task: KTask
    @State private var savedAsTemplate = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            KHairline()
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(String(format: String(localized: "detail.created.date"), relative(task.createdAt)))
                Text(String(format: String(localized: "detail.updated.date"), relative(task.updatedAt)))
                if let completedAt = task.completedAt {
                    Text(String(format: String(localized: "detail.completed.date"), relative(completedAt)))
                }
                if let externalID = task.externalID {
                    Text(externalID)
                }
            }
            .font(Typo.meta)
            .foregroundStyle(Tok.textTertiary)

            // Quiet text control like Delete: snapshots this task and its steps (no dates) as a
            // template for quick add `/name` and the palette. Saved under the task title at once
            // (no naming step; Settings > Data renames it).
            Button {
                guard !savedAsTemplate, TemplateActions.save(taskID: task.id, model: model) != nil else { return }
                // The shell pill (with Manage) comes from the helper; the label swap stays as
                // the in-place confirmation next to the button.
                savedAsTemplate = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedAsTemplate = false }
            } label: {
                Text(String(localized: savedAsTemplate ? "detail.template.saved" : "detail.template.save"))
                    .frame(height: Metrics.minHit, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .font(Typo.meta)
            .buttonStyle(.plain)
            .foregroundStyle(Tok.textTertiary)

            // Shell-level pill (KUndoPill.swift / AppShellView) so it shows regardless of
            // which screen is on top when the inspector's delete fires.
            Button {
                let title = task.title
                model.store.softDelete(task.id)
                model.didMutate()
                UndoToastCenter.shared.show(String(format: String(localized: "undo.deleted.name"), title))
            } label: {
                Text(String(localized: "detail.delete")).kHitTarget()
            }
            .font(Typo.meta)
            .buttonStyle(.plain)
            .foregroundStyle(Tok.textTertiary)
        }
        .padding(.top, Space.x2)
    }

    private func relative(_ date: Date) -> String {
        Self.formatter.localizedString(for: date, relativeTo: Date())
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.dateTimeStyle = .named
        return f
    }()
}
