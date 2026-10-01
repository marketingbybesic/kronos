// Kronos/List/ListBulkControls.swift
// The bulk actions as reusable views: the floating bar (TaskListScreen+Bulk.swift) and the
// inspector's "N tasks selected" state (BulkSelectionPanel) show the SAME controls, both going
// through `ListBulk.apply`. Delete is a separate view because both places set it apart (a
// hairline before it, always last) so it is never adjacent to Done (audit D14).
import SwiftUI
import KronosCore

/// Due date / Priority / Project / Done. Delete is `BulkDeleteButton`.
struct BulkActionControls: View {
    let model: AppModel

    var body: some View {
        let today = Day.today()
        KMenuButton(text: String(localized: "ctx.task.due")) {
            Button(String(localized: "deadline.quick.today")) { ListBulk.apply(.due(today), model: model) }
            Button(String(localized: "deadline.quick.tomorrow")) { ListBulk.apply(.due(today + 1), model: model) }
            Button(String(localized: "deadline.quick.nextweek")) { ListBulk.apply(.due(today + 7), model: model) }
            Button(String(localized: "deadline.quick.none")) { ListBulk.apply(.due(nil), model: model) }
        }
        KMenuButton(text: String(localized: "ctx.task.priority")) {
            ForEach(KPriority.allCases, id: \.self) { p in
                Button(ViewOptionsMapper.priorityName(p)) { ListBulk.apply(.priority(p), model: model) }
            }
        }
        KMenuButton(text: String(localized: "detail.section.project")) {
            Button(String(localized: "detail.noproject")) { ListBulk.apply(.project(nil), model: model) }
            ForEach(model.store.allProjects(), id: \.id) { p in
                Button(p.name) { ListBulk.apply(.project(p), model: model) }
            }
        }
        Button(String(localized: "ctx.task.done")) { ListBulk.apply(.toggleDone, model: model) }
            .kButton(.ghost, size: .compact)
    }
}

struct BulkDeleteButton: View {
    let model: AppModel

    var body: some View {
        Button(String(localized: "ctx.task.delete")) { ListBulk.apply(.delete, model: model) }
            .kButton(.ghost, size: .compact)
    }
}

/// What the inspector shows while 2+ rows are selected, instead of the anchor task alone:
/// the count and the same bulk actions as the floating bar.
struct BulkSelectionPanel: View {
    let model: AppModel

    var body: some View {
        let _ = model.version
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(ListBulk.selectedTasks(model.selectedIDs.count))
                .font(Typo.title)
                .foregroundStyle(Tok.textPrimary)
            VStack(alignment: .leading, spacing: Space.x3) {
                VStack(alignment: .leading, spacing: Space.x3) { BulkActionControls(model: model) }   // stacked: four menus do not fit one inspector row
                KHairline()
                BulkDeleteButton(model: model)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.x5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.bg)
        .accessibilityElement(children: .contain)
    }
}
