// Kronos/Detail/InspectorProjectField.swift
// The Project field of the inspector, in the always-visible summary under effort, deadline and
// priority (it no longer hides behind "Details"). One click opens the type-ahead picker under the
// row: type a few letters, Return files the task there. A step shows its parent's project and cannot
// be moved on its own.
import SwiftUI
import KronosCore

struct InspectorProjectField: View {
    let model: AppModel
    let task: KTask
    /// Snapshot-only: opens the picker on appear with this text typed (nil = closed).
    var previewQuery: String?
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            KPropertyRow(String(localized: "detail.section.project")) {
                if task.isSubtask { inheritedProject } else { valueButton }
            }
            // The row carries its own 8 pt inset (it normally sits in a property list); here it stands
            // under the three attributes, so the inset is taken back to line the label up with theirs.
            .padding(.horizontal, -Space.x2)
            .kTooltip(String(localized: "detail.help.project"))
            if isOpen, !task.isSubtask {
                ProjectPicker(model: model, currentProjectID: task.projectID,
                              onPick: { pick($0) },
                              onCancel: { isOpen = false },
                              initialQuery: previewQuery ?? "")
                    .transition(Motion.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.curve(Motion.fast), value: isOpen)
        .onAppear { if previewQuery != nil { isOpen = true } }
    }

    private var valueButton: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Space.x2) {
                if let project = task.project {
                    KProjectGlyph(icon: project.icon, colorHex: project.colorHex,
                                  isFocus: task.id == model.focusTaskID, size: Metrics.iconM, carrier: .rowGlyph)
                }
                Text(task.project?.name ?? String(localized: "detail.noproject"))
                    .font(Typo.row)
                    .foregroundStyle(task.project == nil ? Tok.textSecondary : Tok.textPrimary)
                    .lineLimit(1)
                Icon(isOpen ? "chevron-down" : "chevron-right", size: Metrics.iconXS)
                    .foregroundStyle(Tok.textTertiary)
            }
            .frame(minHeight: Metrics.minHit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "detail.section.project"))
        .accessibilityValue(task.project?.name ?? String(localized: "detail.noproject"))
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .uiTestAnchor("inspector.project")
    }

    /// A child's project and area are its parent's: shown, not editable (moving a child to
    /// another project is a list action that makes it a standalone task).
    private var inheritedProject: some View {
        HStack(spacing: Space.x2) {
            if let project = task.project {
                KProjectGlyph(icon: project.icon, colorHex: project.colorHex,
                              isFocus: task.id == model.focusTaskID, size: Metrics.iconM, carrier: .rowGlyph)
            }
            Text(task.project?.name ?? String(localized: "detail.noproject"))
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(1)
            Text(String(localized: "detail.project.inherited"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .uiTestAnchor("inspector.project.inherited")
    }

    /// Files the task in `project` (nil = none). An equal pick closes the picker and writes nothing.
    private func pick(_ project: KProject?) {
        isOpen = false
        guard task.projectID != project?.id else { return }
        model.store.move(task.id, toProject: project)
        model.didMutate()
        let message = project.map { SidebarPillText.moved(toProject: $0.name) } ?? String(localized: "detail.project.cleared.pill")
        UndoToastCenter.shared.show(message)
    }
}
