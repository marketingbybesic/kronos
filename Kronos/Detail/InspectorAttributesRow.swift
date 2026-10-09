// The three first-class attributes (effort, deadline, priority) on one labelled row — never
// behind a disclosure. Three equal-width columns with one shared control height; each column's
// button face uses a SHORT value (KMenuButton's Menu label is `.fixedSize()` internally, a
// documented macOS quirk that cannot be worked around, so the face text must already be short
// rather than relying on truncation); the dropdown items underneath still show full names. Falls
// back to two rows only below ~300pt, where three real columns plus captions can't fit at all.
import SwiftUI
import KronosCore

struct InspectorAttributesRow: View {
    let model: AppModel
    let task: KTask

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.x3) {
                effortColumn
                deadlineColumn
                priorityColumn
            }
            VStack(spacing: Space.x3) {
                HStack(alignment: .top, spacing: Space.x3) {
                    effortColumn
                    priorityColumn
                }
                deadlineColumn
            }
        }
    }

    private var effortColumn: some View {
        column(caption: String(localized: "viewoptions.field.effort"), field: .effort, anchor: Self.effortAnchor) {
            KMenuButton(text: task.effort.shortDisplayName) {
                ForEach(KEffort.allCases) { option in
                    Button {
                        model.store.setEffort(task.id, option)
                        model.didMutate()
                    } label: {
                        if option == task.effort {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } leading: {
                if task.effort != .none { KEffortIndicator(level: task.effort.rawValue, of: 5, label: nil, showLabel: false) }  // unset: just the quiet dash
            }
            .accessibilityLabel(String(localized: "viewoptions.field.effort"))
            .accessibilityValue(task.effort.displayName)
        }
    }

    private var priorityColumn: some View {
        column(caption: String(localized: "viewoptions.field.priority"), field: .priority, anchor: Self.priorityAnchor) {
            KMenuButton(text: task.priority.shortDisplayName) {
                ForEach(KPriority.allCases) { option in
                    Button {
                        model.store.setPriority(task.id, option)
                        model.didMutate()
                    } label: {
                        if option == task.priority {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } leading: {
                if task.priority != .none { KPriorityIndicator(level: task.priority.rawValue, of: 4, label: task.priority.displayName, size: Metrics.iconM) }
            }
            .accessibilityLabel(String(localized: "viewoptions.field.priority"))
            .accessibilityValue(task.priority.displayName)
        }
    }

    private var deadlineColumn: some View {
        column(caption: String(localized: "viewoptions.field.deadline"), field: .due, anchor: Self.dueAnchor) {
            InspectorDeadlineControl(model: model, task: task)
        }
    }

    // Live-test anchors, kept on their own lines so the catalog lint never reads them as string keys.
    private static let effortAnchor = "inspector.effort"
    private static let priorityAnchor = "inspector.priority"
    private static let dueAnchor = "inspector.due"

    /// Style G: the three first-class attributes stay together on one row, but the boxed
    /// control-per-column look from the old inspector is gone — a quiet hairline underline is the
    /// only boundary, no fill, no border box, matching the borderless property list below it.
    private func column<Content: View>(caption: String, field: InspectorField, anchor: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(caption)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Metrics.controlCompact)
            KHairline()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kInspectorFieldMenu(field, task: task, model: model)
        .uiTestAnchor(anchor)
    }
}
