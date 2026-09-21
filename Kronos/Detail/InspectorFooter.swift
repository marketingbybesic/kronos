// Footer meta: created / updated (relative, localized), Linear id if externalID is set,
// and a quiet "Delete task" text button — soft delete with a 5s undo pill, wording and
// position distinguishing it from destructive actions rather than colour (no red).
import SwiftUI
import KronosCore

struct InspectorFooter: View {
    let model: AppModel
    let task: KTask

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

            // Shell-level pill (KUndoPill.swift / AppShellView) so it shows regardless of
            // which screen is on top when the inspector's delete fires.
            Button(String(localized: "detail.delete")) {
                let title = task.title
                model.store.softDelete(task.id)
                model.didMutate()
                UndoToastCenter.shared.show(String(format: String(localized: "undo.deleted.name"), title))
            }
            .font(Typo.meta)
            .buttonStyle(.plain)
            .foregroundStyle(Tok.textTertiary)
            .frame(height: Metrics.minHit)
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
