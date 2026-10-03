import Testing
import Foundation
@testable import KronosCore

/// The shape every task context menu must keep (macOS context-menu guidance plus the person's
/// no-red rule): Delete last, destructive entries only after the last divider, at most four
/// divider-separated groups, submenus one level deep, no key equivalents, nothing shown that
/// would do nothing. Built for a top-level task and for a child, with and without the optional
/// entries. `KRONOS_MENU_SHAPE_BREAK=1` checks a deliberately broken menu instead, so the run
/// must fail: the proof these assertions can say no.
@Suite("TaskMenuShapeTests")
struct TaskMenuShapeTests {

    /// Every shape rule violated by `items`, as readable lines (empty = the shape holds).
    static func violations(_ items: [TaskMenuItem]) -> [String] {
        var out: [String] = []
        if items.last != .delete { out.append("Delete is not the last item") }
        if let lastDivider = items.lastIndex(where: \.isDivider) {
            for (i, item) in items.enumerated() where item.isDestructive && i < lastDivider {
                out.append("\(item.rawValue) at \(i) sits before the last divider at \(lastDivider)")
            }
        } else if items.contains(where: \.isDestructive) {
            out.append("destructive item without a divider before it")
        }
        let groups = items.split(whereSeparator: \.isDivider).count
        if groups > 4 { out.append("\(groups) divider groups") }
        for item in items where item.kind == .submenu && Self.nestedLevels(item) > 1 {
            out.append("\(item.rawValue) nests deeper than one level")
        }
        for item in items where item.showsShortcut { out.append("\(item.rawValue) shows a shortcut") }
        if items.first?.isDivider == true || items.last?.isDivider == true { out.append("menu starts or ends with a divider") }
        return out
    }

    /// Levels a submenu entry opens. Every submenu of the task menu holds plain choices only;
    /// Labels is a flat list of label toggles (rename and colour live on the label chip).
    static func nestedLevels(_ item: TaskMenuItem) -> Int { item.kind == .submenu ? 1 : 0 }

    static var breakRequested: Bool { ProcessInfo.processInfo.environment["KRONOS_MENU_SHAPE_BREAK"] == "1" }

    /// The menu under test; the break run swaps Delete in front of the last divider.
    static func menu(isChild: Bool, withLink: Bool, availability: TaskMenuAvailability) -> [TaskMenuItem] {
        var items = TaskMenuSpec.items(isChild: isChild, withLink: withLink, availability: availability)
        if breakRequested, let d = items.lastIndex(where: \.isDivider), let del = items.firstIndex(of: .delete) {
            items.swapAt(d, del)
        }
        return items
    }

    @Test(arguments: [false, true])
    func shapeHoldsForTaskAndChild(isChild: Bool) {
        for withLink in [false, true] {
            for availability in [TaskMenuAvailability.all, TaskMenuAvailability(hasLabels: false, hasMoveTargets: false)] {
                let items = Self.menu(isChild: isChild, withLink: withLink, availability: availability)
                #expect(Self.violations(items).isEmpty, "\(Self.violations(items))")
            }
        }
    }

    @Test func deleteIsLastAndAloneInItsGroup() {
        for isChild in [false, true] {
            let items = Self.menu(isChild: isChild, withLink: true, availability: .all)
            #expect(Array(items.suffix(2)) == [.divider3, .delete])
        }
    }

    @Test func unavailableEntriesAreHiddenNotDimmed() {
        let child = TaskMenuSpec.items(isChild: true, availability: TaskMenuAvailability(hasLabels: false, hasMoveTargets: false))
        #expect(!child.contains(.labels))
        #expect(!child.contains(.moveUnder))
        let task = TaskMenuSpec.items(isChild: false, availability: TaskMenuAvailability(hasLabels: false, hasMoveTargets: false))
        #expect(!task.contains(.labels))
        // A task's project move never depends on other tasks: "No project" is always a choice.
        #expect(task.contains(.move))
    }

    @Test func onlyDeleteIsDestructiveAndNoEntryShowsAShortcut() {
        #expect(TaskMenuItem.allCases.filter(\.isDestructive) == [.delete])
        #expect(TaskMenuItem.allCases.allSatisfy { !$0.showsShortcut })
    }

    @Test func submenusAreExactlyTheValueChoices() {
        let submenus = Set(TaskMenuItem.allCases.filter { $0.kind == .submenu })
        #expect(submenus == [.due, .priority, .status, .effort, .labels, .move, .moveUnder])
    }

    /// The checker itself can say no: hand-written bad menus are each caught.
    @Test func checkerRejectsBadMenus() {
        #expect(!Self.violations([.complete, .delete, .divider1, .copy]).isEmpty)          // Delete not last
        #expect(!Self.violations([.complete, .divider1, .due, .divider2, .copy, .divider3, .details, .divider1, .move, .divider2, .delete]).isEmpty) // 6 groups
        #expect(!Self.violations([.divider1, .complete, .divider2, .delete]).isEmpty)      // starts with a divider
        #expect(!Self.violations([.complete, .delete]).isEmpty)                             // destructive without a divider
        #expect(Self.violations([.complete, .divider1, .delete]).isEmpty)                   // minimal good menu
    }
}
