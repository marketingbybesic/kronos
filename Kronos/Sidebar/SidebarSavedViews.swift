// Kronos/Sidebar/SidebarSavedViews.swift
// The Saved Views section: rows from `store.allSavedViews()` (rev 4). The "+" stays out —
// views are created from the list's "Save as view" (owned by the list leaf), so this
// section only reads, selects, renames and deletes.
import SwiftUI
import KronosCore

struct SidebarSavedViewsSection: View {
    let model: AppModel

    @State private var renameTarget: KSavedView?
    @State private var renameText = ""

    var body: some View {
        // Reading `model.version` makes @Observable re-evaluate `views`/counts on mutation.
        let _ = model.version
        Group {
            if !views.isEmpty {
                KSectionHeader(String(localized: "sidebar.section.views"))
                ForEach(views) { view in
                    row(for: view)
                }
            }
        }
        .popover(item: $renameTarget) { view in
            renameEditor(for: view)
        }
    }

    private var views: [KSavedView] { model.store.allSavedViews() }

    private func row(for view: KSavedView) -> some View {
        KSidebarRow(title: view.name,
                    leadingIcon: "bookmark",
                    count: nilIfZero(count(for: view)),
                    isSelected: model.scope == .savedView(view.id)) {
            select(view)
        }
        .contextMenu {
            Button(String(localized: "common.rename")) {
                renameText = view.name
                renameTarget = view
            }
            Button(String(localized: "common.delete")) {
                model.store.deleteSavedView(view.id)
                model.didMutate()
            }
        }
    }

    private func renameEditor(for view: KSavedView) -> some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(String(localized: "common.rename"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            KTextField(String(localized: "sidebar.projecteditor.name"), text: $renameText)
            HStack {
                Button(String(localized: "common.cancel")) { renameTarget = nil }
                    .kButton(.secondary)
                Spacer()
                Button(String(localized: "common.save")) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    model.store.updateSavedView(view.id, name: trimmed, filter: nil, sort: nil, showDone: nil)
                    model.didMutate()
                    renameTarget = nil
                }
                .kButton(.primary)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.x4)
        .frame(width: Metrics.inspectorMin)
        .background(Tok.overlay)
    }

    private func nilIfZero(_ n: Int) -> Int? { n == 0 ? nil : n }

    /// Open tasks matching the view's own filter — the same rule the list applies when the
    /// view is selected, evaluated here just to count.
    private func count(for view: KSavedView) -> Int {
        let today = Day.today()
        return model.store.allTasks().filter { task in
            KStatus.open.contains(task.status) && view.filter.matches(task, today: today)
        }.count
    }

    private func select(_ view: KSavedView) {
        model.scope = .savedView(view.id)
        model.persist()
    }
}
