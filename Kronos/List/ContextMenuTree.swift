// Kronos/List/ContextMenuTree.swift — context menus as data, rendered.
//
// Every context menu of the task, subtask, label and inspector-field families is built as a
// tree of `CtxNode`s (ContextMenuNodes.swift) by ONE builder, rendered by `CtxMenuView`, and
// attached to its view by ONE modifier (`kContextMenu`). That gives the live UI test the same
// handle on a menu the user has: during a test run the modifier registers the builder under the
// id of the view it is attached to, so "this view really carries this menu" and "this item runs
// this action" are both checkable without synthesising a mouse-tracking menu session.
//
// What is shown is `CtxNodes.visible(...)`: unavailable items are hidden, never dimmed. No item
// uses the system destructive role (macOS may tint it red; the person rule is no red anywhere):
// Delete is a plain item, last, after a divider, and undoable from the pill.
import SwiftUI
import AppKit
import KronosCore

/// Renders nodes as menu items. Used inside `.contextMenu { }`.
struct CtxMenuView: View {
    let nodes: [CtxNode]

    var body: some View {
        ForEach(CtxNodes.visible(nodes)) { CtxNodeView(node: $0) }
    }
}

struct CtxNodeView: View {
    let node: CtxNode

    var body: some View {
        switch node.kind {
        case .divider:
            Divider()
        case .action(let run):
            Button(action: run) {
                if node.checked {
                    Label(node.title, systemImage: "checkmark")
                } else {
                    Text(node.title)
                }
            }
            .ctxHelp(node.help)
        case .submenu(let kids):
            Menu(node.title) { CtxMenuView(nodes: kids) }
                .ctxHelp(node.help)
        }
    }
}

/// Menus currently attached to a rendered view, by the id the view gave them. Filled only
/// while the live UI test runs (`KRONOS_UITEST`); empty and untouched in a normal launch.
@MainActor
enum CtxMenuRegistry {
    static var providers: [String: @MainActor () -> [CtxNode]] = [:]

    static func nodes(_ id: String) -> [CtxNode]? { providers[id]?() }
    static var ids: [String] { providers.keys.sorted() }
}

private struct CtxMenuAttach: ViewModifier {
    let id: String
    let nodes: @MainActor () -> [CtxNode]

    func body(content: Content) -> some View {
        content
            // The whole frame answers a right click, not just the glyph and text pixels.
            .contentShape(Rectangle())
            .contextMenu { CtxMenuView(nodes: nodes()) }
            .uiTestAnchor("ctx." + id)
            .onAppear { register(id) }
            .onChange(of: id) { old, new in
                unregister(old)
                register(new)
            }
            .onDisappear { unregister(id) }
    }

    private func register(_ key: String) {
        guard UITestAnchors.isOn else { return }
        CtxMenuRegistry.providers[key] = nodes
    }

    private func unregister(_ key: String) {
        guard UITestAnchors.isOn else { return }
        CtxMenuRegistry.providers[key] = nil
    }
}

extension View {
    /// A tooltip only when the item has one (an empty tooltip string still installs a tag).
    @ViewBuilder
    fileprivate func ctxHelp(_ text: String?) -> some View {
        if let text { self.help(text) } else { self }
    }

    /// Attach the context menu built by `nodes` to this view. `id` names the view for the live
    /// UI test and must be unique among views on screen at once.
    func kContextMenu(id: String, nodes: @escaping @MainActor () -> [CtxNode]) -> some View {
        modifier(CtxMenuAttach(id: id, nodes: nodes))
    }
}
