// Kronos/List/ContextMenuNodes.swift — the data half of every context menu.
//
// Foundation only (no SwiftUI/AppKit), so scripts/bulk-selftest.swift compiles THIS file against
// hand-written cases. ContextMenuTree.swift renders the nodes and attaches them to views.
//
// macOS context menus hide what is unavailable instead of dimming it, and keep submenus to one
// level: `CtxNodes.visible` is the one place that turns a built tree into what is shown, so a
// builder may still mark an item `enabled: false` (the live test can then prove that invoking it
// does nothing) without the person ever seeing a greyed-out row.
import Foundation

/// One entry of a context menu.
struct CtxNode: Identifiable {
    enum Kind {
        case action(@MainActor () -> Void)
        case submenu([CtxNode])
        case divider
    }

    /// Stable within one menu ("due.today", "priority.high"); the test addresses items by it.
    let id: String
    let title: String
    var enabled = true
    var checked = false
    /// Removes or overwrites data. Only decides placement (last, after a divider); it is never
    /// rendered differently (no system destructive role, no red: person rule).
    var destructive = false
    /// Tooltip for an item whose meaning is not obvious (glosses for Avoiding it, Break down, ...).
    var help: String?
    let kind: Kind

    static func action(_ id: String, _ title: String, enabled: Bool = true, checked: Bool = false,
                       destructive: Bool = false, help: String? = nil,
                       _ run: @escaping @MainActor () -> Void) -> CtxNode {
        CtxNode(id: id, title: title, enabled: enabled, checked: checked, destructive: destructive, help: help, kind: .action(run))
    }

    static func submenu(_ id: String, _ title: String, enabled: Bool = true, help: String? = nil, _ children: [CtxNode]) -> CtxNode {
        CtxNode(id: id, title: title, enabled: enabled, help: help, kind: .submenu(children))
    }

    static func divider(_ id: String) -> CtxNode {
        CtxNode(id: id, title: "", kind: .divider)
    }

    var isDivider: Bool { if case .divider = kind { return true } else { return false } }
}

/// Pure tree helpers (no actor needed); only `invoke` runs an action and so needs the main actor.
enum CtxNodes {
    /// Depth-first search by id.
    static func find(_ id: String, in nodes: [CtxNode]) -> CtxNode? {
        for n in nodes {
            if n.id == id { return n }
            if case .submenu(let kids) = n.kind, let hit = find(id, in: kids) { return hit }
        }
        return nil
    }

    /// Runs the action behind `id`. False (and nothing runs) when the item is missing,
    /// disabled or not an action: the same rule the rendered menu applies (a disabled item is
    /// not even shown).
    @MainActor @discardableResult
    static func invoke(_ id: String, in nodes: [CtxNode]) -> Bool {
        guard let n = find(id, in: nodes), n.enabled, case .action(let run) = n.kind else { return false }
        run()
        return true
    }

    /// Every id in the tree, for diagnostics.
    static func ids(_ nodes: [CtxNode]) -> [String] {
        nodes.flatMap { n -> [String] in
            if case .submenu(let kids) = n.kind { return [n.id] + ids(kids) }
            return [n.id]
        }
    }

    /// What is shown: disabled items and submenus left with no visible child are dropped, then
    /// dividers that would lead, trail or double up. Applied at every level.
    static func visible(_ nodes: [CtxNode]) -> [CtxNode] {
        var kept: [CtxNode] = []
        for n in nodes where n.enabled {
            switch n.kind {
            case .submenu(let kids):
                let shown = visible(kids)
                guard shown.contains(where: { !$0.isDivider }) else { continue }
                kept.append(CtxNode(id: n.id, title: n.title, enabled: true, checked: n.checked,
                                    destructive: n.destructive, help: n.help, kind: .submenu(shown)))
            case .divider:
                if let last = kept.last, !last.isDivider { kept.append(n) }
            case .action:
                kept.append(n)
            }
        }
        while kept.last?.isDivider == true { kept.removeLast() }
        return kept
    }

    /// Submenu levels below the top menu: 0 for a flat menu, 1 when submenus hold plain items.
    static func depth(_ nodes: [CtxNode]) -> Int {
        nodes.map { n -> Int in
            if case .submenu(let kids) = n.kind { return 1 + depth(kids) }
            return 0
        }.max() ?? 0
    }

    /// True when any node in the tree is disabled (it would be hidden, never dimmed).
    static func containsDisabled(_ nodes: [CtxNode]) -> Bool {
        nodes.contains { n in
            if !n.enabled { return true }
            if case .submenu(let kids) = n.kind { return containsDisabled(kids) }
            return false
        }
    }
}
