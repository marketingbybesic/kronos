// Kronos/Sidebar/SidebarArchived.swift
// The Archived disclosure at the bottom of the areas list: every archived project
// (`allProjects(includeArchived: true)` minus the live ones, rev 4), each restorable.
import SwiftUI
import KronosCore

struct SidebarArchivedSection: View {
    let model: AppModel
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        // Reading `model.version` makes @Observable re-evaluate `archived` on mutation.
        let _ = model.version
        Group {
            if !archived.isEmpty {
                header
                if isExpanded {
                    ForEach(archived) { project in
                        row(for: project)
                    }
                }
            }
        }
    }

    private var archived: [KProject] {
        let live = Set(model.store.allProjects().map(\.id))
        return model.store.allProjects(includeArchived: true).filter { !live.contains($0.id) }
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack {
                Text(String(localized: "sidebar.section.archived"))
                    .font(Typo.sectionHdr)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
                Icon(isExpanded ? "chevron-down" : "chevron-right", size: Metrics.iconS)
                    .foregroundStyle(Tok.textTertiary)
            }
            .padding(.leading, Metrics.sidebarRowLeading)
            .padding(.trailing, Metrics.sidebarRowTrailing)
            .frame(height: Metrics.groupHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Metrics.sidebarSectionGapTop)
        .padding(.bottom, Metrics.sidebarSectionGapBottom)
        .accessibilityLabel(String(localized: "sidebar.showarchived"))
    }

    private func row(for project: KProject) -> some View {
        KSidebarRow(title: project.name,
                    projectIcon: project.icon,
                    colorHex: project.colorHex,
                    isArchived: true) {}
            .contextMenu {
                Button(String(localized: "sidebar.projecteditor.restore")) {
                    model.store.restoreProject(project.id)
                    model.didMutate()
                }
            }
    }
}
