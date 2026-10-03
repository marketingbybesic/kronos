// Kronos/List/ListBulkControls.swift
// The bulk actions as reusable views: the floating bar (TaskListScreen+Bulk.swift) and the
// inspector's "N tasks selected" state (BulkSelectionPanel) show the SAME controls, all going
// through `ListBulk.apply` (one undo step and one pill each). Date, Priority, Status, Project and
// Labels are menus; Complete is the one direct action. The Date menu carries the same choices as
// every date menu (Today · Tomorrow · Next week · Pick… · Clear) plus the two plans that used to
// be a separate Snooze (plan for today, snooze to tomorrow). Delete is a separate view because
// both places set it apart (a hairline before it, always last) so it is never adjacent to
// Complete (audit D14). Every action reads in primary text; a menu that has nothing to offer
// (no labels yet) is not shown.
import SwiftUI
import KronosCore

/// Date / Priority / Status / Project / Labels / Complete. Delete is `BulkDeleteButton`.
struct BulkActionControls: View {
    let model: AppModel
    @State private var pickingDate = false

    var body: some View {
        let _ = model.version
        let today = Day.today()
        KMenuButton(text: String(localized: "list.bulk.date")) {
            Button(String(localized: "deadline.quick.today")) { ListBulk.apply(.due(today), model: model) }
            Button(String(localized: "deadline.quick.tomorrow")) { ListBulk.apply(.due(today + 1), model: model) }
            Button(String(localized: "deadline.quick.nextweek")) { ListBulk.apply(.due(today + 7), model: model) }
            Button(String(localized: "ctx.field.pick")) { pickingDate = true }
            Button(String(localized: "ctx.field.clear")) { ListBulk.apply(.due(nil), model: model) }
            Divider()
            Button(String(localized: "hotkey.list.plantoday")) { ListBulk.apply(.plan(today), model: model) }
            Button(String(localized: "hotkey.list.snooze")) { ListBulk.apply(.snooze, model: model) }
        }
        .popover(isPresented: $pickingDate, arrowEdge: .top) {
            ListDueField(current: nil) { day in
                pickingDate = false
                ListBulk.apply(.due(day), model: model)
            }
        }
        .uiTestAnchor("bulk.date")
        KMenuButton(text: String(localized: "ctx.task.priority")) {
            ForEach(KPriority.allCases, id: \.self) { p in
                Button(ViewOptionsMapper.priorityName(p)) { ListBulk.apply(.priority(p), model: model) }
            }
        }
        KMenuButton(text: String(localized: "ctx.task.status")) {
            ForEach([KStatus.todo, .inProgress, .waiting, .someday], id: \.self) { st in
                Button(ViewOptionsMapper.statusName(st)) {
                    ListBulk.apply(.status(st), model: model)
                }
            }
        }
        .uiTestAnchor("bulk.status")
        KMenuButton(text: String(localized: "detail.section.project")) {
            Button(String(localized: "detail.noproject")) { ListBulk.apply(.project(nil), model: model) }
            ForEach(model.store.allProjects(), id: \.id) { p in
                Button(p.name) { ListBulk.apply(.project(p), model: model) }
            }
        }
        let labels = model.store.labels().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !labels.isEmpty {
            KMenuButton(text: String(localized: "ctx.task.label")) {
                ForEach(labels, id: \.id) { label in
                    Button {
                        ListBulk.apply(.toggleLabel(label), model: model)
                    } label: {
                        if allCarry(label) { Label(label.name, systemImage: "checkmark") } else { Text(label.name) }
                    }
                }
            }
            .uiTestAnchor("bulk.labels")
        }
        Button(String(localized: "bar.menu.complete")) { ListBulk.apply(.toggleDone, model: model) }
            .kButton(.secondary, size: .compact)
            .fixedSize()
    }

    /// Every selected task already carries the label (its toggle then removes it from all).
    private func allCarry(_ label: KLabel) -> Bool {
        let tasks = model.selectedIDs.compactMap { model.store.task($0) }
        return !tasks.isEmpty && tasks.allSatisfy { ($0.labels ?? []).contains { $0.id == label.id } }
    }
}

struct BulkDeleteButton: View {
    let model: AppModel

    var body: some View {
        Button(String(localized: "ctx.task.delete")) { ListBulk.apply(.delete, model: model) }
            .kButton(.secondary, size: .compact)
            .fixedSize()
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
                VStack(alignment: .leading, spacing: Space.x3) { BulkActionControls(model: model) }   // stacked: the menus do not fit one inspector row
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
