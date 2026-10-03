// Kronos/App/LiveUITest+EntrySurfaces.swift
// Live steps for the entry field on the other surfaces: the inline add row of a project list
// (prefilled, removable destination pill) and the pills of a Capture review row.
// Keys and clicks are synthetic NSEvents posted to the app's own window; assertions read the
// store and the ui-test anchors, never the text a view happens to show.
// Compiled only outside Release, like the rest of the live test.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {

    private static func surfSettle(_ ms: Int = 450) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private static func surfKeyWindow(_ main: NSWindow) async {
        for _ in 0..<20 {
            if NSApp.isActive, main.isKeyWindow { return }
            NSApp.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
            await surfSettle(150)
        }
    }

    private static func surfType(_ text: String) async {
        for ch in text { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        await surfSettle(250)
    }

    static func entrySurfaceSteps(_ model: AppModel) async {
        let store = model.store
        let main = window!
        window = main
        let name = "Inline pill project"
        let proj = store.allProjects().first { $0.name == name } ?? store.createProject(name: name)
        model.didMutate()

        // Inline add row: over a project list the destination is a prefilled pill.
        model.scope = .project(proj.id)
        await surfKeyWindow(main)
        await surfSettle(700)
        record("inline row: a project list shows its project as a pill in the add row",
               UITestAnchors.frames["entry.pill.destination"] != nil && UITestAnchors.frames["inlineadd.field"] != nil,
               "pill=\(UITestAnchors.frames["entry.pill.destination"] != nil) field=\(UITestAnchors.frames["inlineadd.field"] != nil)")

        var ok = await click("inlineadd.field", xFraction: 0.3)
        await surfSettle(300)
        await surfType("Inline pill task")
        key("\r", keyCode: 36); await surfSettle(700)
        let first = store.allTasks().first { $0.title == "Inline pill task" }
        record("inline row: Return files the task into the list's project and the pill stays for the next one",
               ok && first?.project?.id == proj.id && UITestAnchors.frames["entry.pill.destination"] != nil,
               "found=\(ok) project=\(first?.project?.name ?? "nil") pill=\(UITestAnchors.frames["entry.pill.destination"] != nil)")

        // Removing the pill: the next task has no project, and the pill is back after that add.
        ok = await click("entry.pill.destination.remove")
        await surfSettle(400)
        let gone = UITestAnchors.frames["entry.pill.destination"] == nil
        _ = await click("inlineadd.field", xFraction: 0.3)
        await surfSettle(300)
        await surfType("Inline no project")
        key("\r", keyCode: 36); await surfSettle(700)
        let second = store.allTasks().first { $0.title == "Inline no project" }
        record("inline row: x on the pill removes it and the next task has no project",
               ok && gone && second != nil && second?.project == nil,
               "clicked=\(ok) pillGone=\(gone) task=\(second != nil) project=\(second?.project?.name ?? "nil")")
        record("inline row: after an add the inherited pill returns",
               UITestAnchors.frames["entry.pill.destination"] != nil,
               "pill=\(UITestAnchors.frames["entry.pill.destination"] != nil)")

        // A typed token beats the inherited pill.
        let other = store.allProjects().first { $0.name == "Hit list" } ?? store.createProject(name: "Hit list")
        model.didMutate()
        _ = await click("inlineadd.field", xFraction: 0.3)
        await surfSettle(300)
        await surfType("Inline typed token #hit list ")
        key("\r", keyCode: 36); await surfSettle(700)
        let third = store.allTasks().first { $0.title == "Inline typed token" }
        record("inline row: a typed #project beats the prefilled pill",
               third?.project?.id == other.id, "project=\(third?.project?.name ?? "nil") title=\(third?.title ?? "nil")")

        // Back on Inbox the row has no pill.
        model.scope = .inbox
        await surfKeyWindow(main)
        await surfSettle(700)
        record("inline row: on Inbox the add row has no pill",
               UITestAnchors.frames["entry.pill.destination"] == nil && UITestAnchors.frames["inlineadd.field"] != nil,
               "pill=\(UITestAnchors.frames["entry.pill.destination"] != nil)")

        // Capture: a parsed @label shows as a pill on the review row.
        let before = store.allTasks().count
        model.isCaptureOpen = false
        await surfSettle(300)
        model.openCapture(with: "Surface pill offer #hit list @finance !!")
        await surfSettle(1200)
        record("capture: a parsed @label shows as a pill on its review row",
               UITestAnchors.frames["capture.review"] != nil && UITestAnchors.frames["capture.row.pill.label"] != nil,
               "review=\(UITestAnchors.frames["capture.review"] != nil) pill=\(UITestAnchors.frames["capture.row.pill.label"] != nil)")
        model.isCaptureOpen = false
        await surfSettle(400)
        record("capture: reviewing without creating leaves the store untouched",
               store.allTasks().count == before, "before=\(before) after=\(store.allTasks().count)")
    }
}
#endif
