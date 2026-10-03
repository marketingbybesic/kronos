// Kronos/List/LabelContextMenu.swift — label menus.
//
// A label renders as a chip in the inspector; its menu (Rename, Colour ▸, Filter by label,
// Remove from task) attaches to that chip. The task row's own menu carries the same entries
// per assigned label plus "Add label ▸". Rename, colour and add/remove are one undo step
// each and update every place the label shows at once (they all read the shared KLabel).
import SwiftUI
import AppKit
import KronosCore

@MainActor
enum LabelMenu {
    /// Menu of one label. `task` is the task the label is shown on: "Remove from task"
    /// exists only when there is one.
    static func nodes(label: KLabel, task: KTask?, model: AppModel) -> [CtxNode] {
        let store = model.store
        let labelID = label.id

        let colours: [CtxNode] = KProjectPalette.orderedSwatches.map { swatch -> CtxNode in
            let hex = "#" + swatch.hex
            return .action("colour.\(swatch.hex)", KProjectPalette.displayName(for: swatch.name),
                           checked: label.colorHex.caseInsensitiveCompare(hex) == .orderedSame) {
                guard label.colorHex.caseInsensitiveCompare(hex) != .orderedSame else { return }
                store.setLabelColor(labelID, hex: hex)
                model.commit(String(format: String(localized: "list.pill.labelcolour"), label.name))
            }
        }

        var items: [CtxNode] = [
            .action("rename", String(localized: "ctx.label.rename")) {
                LabelRenameAlert.run(labelID: labelID, model: model)
            },
            .submenu("colour", String(localized: "ctx.label.colour"), colours),
            .action("filter", String(localized: "ctx.label.filter")) {
                filterByLabel(labelID, model: model)
            },
        ]
        if let task {
            let taskID = task.id
            items.append(.divider("div"))
            items.append(.action("remove", String(localized: "ctx.label.removefromtask")) {
                store.removeLabel(label, from: taskID)
                model.commit(String(format: String(localized: "list.pill.labelremoved"), label.name, task.title))
            })
        }
        return items
    }

    /// Show only tasks carrying this label in the current list. View state, not data:
    /// nothing is pushed on the undo stack, and choosing the label that is already the
    /// whole label filter changes nothing.
    static func filterByLabel(_ id: UUID, model: AppModel) {
        var options = model.options(for: model.scope)
        guard options.filter.labelIDs != [id] else { return }
        options.filter.labelIDs = [id]
        model.setOptions(options, for: model.scope)
        model.didMutate()   // refresh-only: view filter state, not a store write
    }

    /// The task menu's Labels submenu: every label as one checked toggle (on the task or not), a
    /// flat list one level deep. Rename, colour and filter live on the label chip's own menu.
    static func taskToggleNodes(task: KTask, model: AppModel) -> [CtxNode] {
        let store = model.store
        let taskID = task.id
        let assignedIDs = Set((task.labels ?? []).map(\.id))
        return store.labels()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { (label: KLabel) -> CtxNode in
                let on = assignedIDs.contains(label.id)
                return .action("label.\(label.id.uuidString)", label.name, checked: on) {
                    if on {
                        store.removeLabel(label, from: taskID)
                        model.commit(String(format: String(localized: "list.pill.labelremoved"), label.name, task.title))
                    } else {
                        store.addLabel(label, to: taskID)
                        model.commit(String(format: String(localized: "list.pill.labeladded"), label.name, task.title))
                    }
                }
            }
    }
}

/// The task row's label entries (kept as a view so the row's menu needs no knowledge of nodes).
struct LabelContextMenu: View {
    let task: KTask
    let model: AppModel

    var body: some View {
        CtxMenuView(nodes: LabelMenu.taskToggleNodes(task: task, model: model))
    }
}

/// Rename prompt. A modal alert needs no host view, so the same call works from a chip's
/// menu and from the task row's menu.
@MainActor
enum LabelRenameAlert {
    static func run(labelID: UUID, model: AppModel) {
        guard let label = model.store.label(id: labelID) else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = label.name
        let alert = NSAlert()
        alert.messageText = String(localized: "ctx.label.rename.title")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "common.rename"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch model.store.renameLabel(labelID, to: field.stringValue) {
        case .renamed:
            model.commit(String(format: String(localized: "list.pill.labelrenamed"), field.stringValue))
        case .duplicate:
            let note = NSAlert()
            note.messageText = String(localized: "ctx.label.rename.duplicate")
            note.runModal()   // AppKit supplies the localised default "OK" button
        case .unchanged, .empty, .notFound:
            break
        }
    }
}

private struct LabelMenuModifier: ViewModifier {
    let label: KLabel
    let task: KTask?
    let model: AppModel

    func body(content: Content) -> some View {
        content.kContextMenu(id: "chip.\(label.id.uuidString)") {
            LabelMenu.nodes(label: label, task: task, model: model)
        }
    }
}

extension View {
    /// The label menu on a label chip (Rename, Colour ▸, Filter by label, Remove from task).
    func kLabelContextMenu(_ label: KLabel, task: KTask?, model: AppModel) -> some View {
        modifier(LabelMenuModifier(label: label, task: task, model: model))
    }
}
