import Foundation

/// One entry of a task's context menu. The raw value is the stable id the app's menu nodes use.
public enum TaskMenuItem: String, CaseIterable, Sendable {
    case complete, focus
    /// "Avoiding it": the dread toggle, right behind Focus (how the person relates to the task).
    case dread
    case breakdown, details
    case due, priority, status, effort, labels
    /// Task only: move to a project / no project.
    case move
    /// Child only: become a standalone task right behind the parent.
    case standalone
    /// Child only: re-parent under another task.
    case moveUnder
    case copy
    /// Puts the `kronos://open?id=` link of the task on the pasteboard (see `TaskLink`).
    case copyLink
    case delete
    case divider1, divider2, divider3

    public var isDivider: Bool { self == .divider1 || self == .divider2 || self == .divider3 }

    /// What the entry is in the rendered menu.
    public enum Kind: Sendable, Equatable {
        /// Runs at once.
        case action
        /// Opens one level of plain choices (never a further submenu).
        case submenu
        case divider
    }

    public var kind: Kind {
        switch self {
        case .divider1, .divider2, .divider3: return .divider
        case .due, .priority, .status, .effort, .labels, .move, .moveUnder: return .submenu
        default: return .action
        }
    }

    /// Removes or overwrites the task. Destructive entries sit after the last divider, last in
    /// the menu, and are undoable (the app never tints them: no red anywhere).
    public var isDestructive: Bool { self == .delete }

    /// Context menus never show key equivalents (HIG); the list keys live in the legend and the
    /// keymap. Kept as a property so a shape test can hold every entry to it.
    public var showsShortcut: Bool { false }
}

/// What the task and the store currently offer, so the menu can hide what would do nothing
/// (macOS context menus hide unavailable items instead of dimming them).
public struct TaskMenuAvailability: Sendable, Equatable {
    /// At least one label exists to toggle on the task.
    public var hasLabels: Bool
    /// At least one other task a child could move under.
    public var hasMoveTargets: Bool

    public init(hasLabels: Bool = true, hasMoveTargets: Bool = true) {
        self.hasLabels = hasLabels
        self.hasMoveTargets = hasMoveTargets
    }

    /// Everything offered (the shape of the full menu).
    public static let all = TaskMenuAvailability()
}

/// Which entries a task menu has. ONE list drives the menu of a top-level task and of a child
/// task, so the two cannot drift: a child gets everything a task has except what breaks a task
/// down into subtasks or moves it to another project (a child follows its parent's project),
/// plus the two child-only conversions.
public enum TaskMenuSpec {
    /// `withLink` adds "Copy Kronos link" right behind "Copy" (the app passes true; the list
    /// without it is the original menu). `availability` drops entries that would offer nothing.
    public static func items(isChild: Bool, withLink: Bool = false,
                             availability: TaskMenuAvailability = .all) -> [TaskMenuItem] {
        var items: [TaskMenuItem] = [.complete, .focus, .dread]
        if !isChild { items.append(.breakdown) }
        items += [.details, .divider1, .due, .priority, .status, .effort]
        if availability.hasLabels { items.append(.labels) }
        items.append(.divider2)
        if isChild {
            items.append(.standalone)
            if availability.hasMoveTargets { items.append(.moveUnder) }
        } else {
            items.append(.move)
        }
        items.append(.copy)
        if withLink { items.append(.copyLink) }
        items += [.divider3, .delete]
        return items
    }

    /// Entries that add subtasks to, or break down, a task: never on a child (one level only).
    public static let addsSubtasks: Set<TaskMenuItem> = [.breakdown]
}

/// The `kronos://open?id=<uuid>` link of a task: what "Copy Kronos link" and a drag out of the
/// list put on the pasteboard, and what the URL handler opens (`kronos://open`, see URLScheme).
public enum TaskLink {
    public static func url(for id: UUID) -> URL {
        URL(string: "kronos://open?id=\(id.uuidString)")!
    }

    public static func string(for id: UUID) -> String { url(for: id).absoluteString }
}
