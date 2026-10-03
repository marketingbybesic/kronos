// Kronos/App/LiveUITest+SubtaskEntry.swift
// Live steps for the add-subtask entry field (middle list row and inspector steps section):
// a task's syntax minus the project, one undo step per entry, `#project` ignored and shown as an
// ignored pill, never moving the child. Keys and clicks are synthetic NSEvents posted to the
// app's own window; assertions read the store and the anchors.
// Compiled only outside Release, like the rest of the live test.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {

    private static func subSettle(_ ms: Int = 450) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private static func subType(_ text: String) async {
        for ch in text { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        await subSettle(250)
    }

    static func subtaskEntrySteps(_ model: AppModel) async {
        let store = model.store
        let main = window!
        window = main
        for _ in 0..<20 {
            if NSApp.isActive, main.isKeyWindow { break }
            NSApp.activate(ignoringOtherApps: true)
            main.makeKeyAndOrderFront(nil)
            await subSettle(150)
        }

        let project = store.createProject(name: "subentry.fixture")
        let parent = store.create(title: "subentry.parent", project: project)
        _ = store.addSubtask(parent.id, title: "subentry.existing")
        model.didMutate()
        model.scope = .project(project.id)
        await subSettle(700)
        await expandAll()

        let listAnchor = "subtask.add.list.\(parent.id.uuidString)"
        record("subtask entry: the add-subtask row shows under an expanded parent",
               UITestAnchors.frames[listAnchor] != nil, "anchor=\(UITestAnchors.frames[listAnchor] != nil)")

        // Full syntax: priority, date word, label; one undo step removes the whole child.
        var ok = await click(listAnchor, xFraction: 0.3)
        await subSettle(300)
        await subType("Book flight !! sutra @travel")
        key("\r", keyCode: 36); await subSettle(700)
        let child = store.children(of: parent.id).first { $0.title == "Book flight" }
        record("subtask entry: \"Book flight !! sutra @travel\" makes one child with priority, due and label",
               ok && child != nil && child?.priority == .medium && child?.dueDay == Day.today() + 1
                   && child?.labels?.map(\.name) == ["travel"] && child?.parentID == parent.id,
               "found=\(ok) child=\(child != nil) priority=\(String(describing: child?.priority)) due=\(String(describing: child?.dueDay)) today=\(Day.today()) labels=\(child?.labels?.map(\.name) ?? [])")
        record("subtask entry: the child keeps the parent's project",
               child?.project?.id == project.id, "project=\(child?.project?.name ?? "nil")")

        key("z", modifiers: .command, keyCode: 6); await subSettle(600)
        let afterUndo = store.children(of: parent.id).map(\.title)
        record("subtask entry: one Cmd-Z removes the whole child (title, priority, due, label)",
               !afterUndo.contains("Book flight") && afterUndo.contains("subentry.existing"),
               "children=\(afterUndo)")

        // A typed #project is ignored: an ignored pill shows, the child stays under its parent.
        ok = await click(listAnchor, xFraction: 0.3)
        await subSettle(300)
        await subType("Print tickets #hit ")
        let pillShown = UITestAnchors.frames["entry.pill.ignored"] != nil
        record("subtask entry: a typed #project shows as an ignored pill and offers no project list",
               ok && pillShown && UITestAnchors.frames["entry.list"] == nil,
               "pill=\(pillShown) list=\(UITestAnchors.frames["entry.list"] != nil)")
        key("\r", keyCode: 36); await subSettle(700)
        let printed = store.children(of: parent.id).first { $0.title.hasPrefix("Print tickets") }
        record("subtask entry: the child with an ignored #project stays under its parent in the parent's project",
               printed != nil && printed?.parentID == parent.id && printed?.project?.id == project.id,
               "child=\(printed?.title ?? "nil") parent=\(printed?.parentID == parent.id) project=\(printed?.project?.name ?? "nil")")

        // Inspector steps section: same field, same grammar.
        model.selectedTaskID = parent.id
        await subSettle(800)
        let inspAnchor = "subtask.add.inspector.\(parent.id.uuidString)"
        ok = await click(inspAnchor, xFraction: 0.3)
        await subSettle(300)
        await subType("Inspector step !!! *m")
        key("\r", keyCode: 36); await subSettle(700)
        let step = store.children(of: parent.id).first { $0.title == "Inspector step" }
        record("subtask entry: the inspector field takes priority and effort tokens",
               ok && step?.priority == .high && step?.effort == .m,
               "found=\(ok) step=\(step != nil) priority=\(String(describing: step?.priority)) effort=\(String(describing: step?.effort))")
        key("z", modifiers: .command, keyCode: 6); await subSettle(600)
        record("subtask entry: one Cmd-Z removes the inspector step",
               !store.children(of: parent.id).contains { $0.title == "Inspector step" },
               "children=\(store.children(of: parent.id).map(\.title))")
    }
}
#endif
