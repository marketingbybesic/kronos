import Testing
import Foundation
@testable import KronosCore

/// The task menu and the child-task menu come from one list; both are written out by hand here.
@Suite("TaskMenuSpecTests")
struct TaskMenuSpecTests {

    @Test func topLevelTaskMenu() {
        let want = ["complete", "focus", "dread", "breakdown", "details", "divider1",
                    "due", "priority", "status", "effort", "labels", "divider2",
                    "move", "copy", "divider3", "delete"]
        #expect(TaskMenuSpec.items(isChild: false).map(\.rawValue) == want)
    }

    @Test func childTaskMenu() {
        let want = ["complete", "focus", "dread", "details", "divider1",
                    "due", "priority", "status", "effort", "labels", "divider2",
                    "standalone", "moveUnder", "copy", "divider3", "delete"]
        #expect(TaskMenuSpec.items(isChild: true).map(\.rawValue) == want)
    }

    @Test func avoidingItFollowsFocusOnBothMenus() {
        for isChild in [false, true] {
            let items = TaskMenuSpec.items(isChild: isChild, withLink: true)
            let focus = items.firstIndex(of: .focus)
            #expect(focus != nil)
            #expect(focus.map { items[$0 + 1] } == .dread)
        }
    }

    @Test func withLinkPutsCopyLinkRightBehindCopy() {
        let want = ["complete", "focus", "dread", "breakdown", "details", "divider1",
                    "due", "priority", "status", "effort", "labels", "divider2",
                    "move", "copy", "copyLink", "divider3", "delete"]
        #expect(TaskMenuSpec.items(isChild: false, withLink: true).map(\.rawValue) == want)
    }

    @Test func childHasNothingThatAddsSubtasksAndEverythingElseATaskHas() {
        let task = Set(TaskMenuSpec.items(isChild: false))
        let child = Set(TaskMenuSpec.items(isChild: true))
        #expect(child.isDisjoint(with: TaskMenuSpec.addsSubtasks))
        // What a task has and a child lacks is exactly the subtask entry and the project move.
        #expect(task.subtracting(child) == [.breakdown, .move])
        #expect(child.subtracting(task) == [.standalone, .moveUnder])
    }

    @Test func noMenuStartsOrEndsWithADividerOrDoublesOne() {
        for isChild in [false, true] {
            for availability in [TaskMenuAvailability.all, TaskMenuAvailability(hasLabels: false, hasMoveTargets: false)] {
                let items = TaskMenuSpec.items(isChild: isChild, availability: availability)
                #expect(items.first?.isDivider == false)
                #expect(items.last?.isDivider == false)
                for (a, b) in zip(items, items.dropFirst()) { #expect(!(a.isDivider && b.isDivider)) }
            }
        }
    }
}
