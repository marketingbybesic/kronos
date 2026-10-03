import Testing
import Foundation
@testable import KronosCore

/// "Copy Kronos link" sits right behind "Copy" in both menus, and the link has one exact shape.
@Suite("TaskLinkMenuTests")
struct TaskLinkMenuTests {

    @Test func topLevelMenuWithLink() {
        let want = ["complete", "focus", "dread", "breakdown", "details", "divider1",
                    "due", "priority", "status", "effort", "labels", "divider2",
                    "move", "copy", "copyLink", "divider3", "delete"]
        #expect(TaskMenuSpec.items(isChild: false, withLink: true).map(\.rawValue) == want)
    }

    @Test func childMenuWithLink() {
        let want = ["complete", "focus", "dread", "details", "divider1",
                    "due", "priority", "status", "effort", "labels", "divider2",
                    "standalone", "moveUnder", "copy", "copyLink", "divider3", "delete"]
        #expect(TaskMenuSpec.items(isChild: true, withLink: true).map(\.rawValue) == want)
    }

    @Test func menuWithoutLinkIsTheOriginal() {
        #expect(!TaskMenuSpec.items(isChild: false).contains(.copyLink))
        #expect(!TaskMenuSpec.items(isChild: true).contains(.copyLink))
    }

    @Test func linkShape() {
        let id = UUID(uuidString: "0F8C2A4E-7B1D-4C3A-9E55-1A2B3C4D5E6F")!
        #expect(TaskLink.string(for: id) == "kronos://open?id=0F8C2A4E-7B1D-4C3A-9E55-1A2B3C4D5E6F")
        #expect(TaskLink.url(for: id).scheme == "kronos")
        #expect(TaskLink.url(for: id).host == "open")
    }
}
