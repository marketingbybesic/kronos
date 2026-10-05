// Live steps for dragging a task row out of Kronos: the private marker type goes first, plain text
// is a readable dossier ending in the kronos:// link, and Kronos's own drop reader still sees a
// task. Run alone with `--only group:A-DRAG`; the in-app reorder / drop-on-project regressions are
// the existing `group:D-STORE` and `group:C-SIDEBAR` steps, whose pasteboards now carry the real shape.
// Private named pasteboards only. `KRONOS_UITEST_BREAK=1` flips one expectation: the run must fail.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func aDragSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        guard KronosEnv.isHermetic else { record("A-DRAG runs only on a scratch store", false, "not hermetic"); return }
        let store = model.store
        let project = store.createProject(name: "adrag.project")
        let task = store.create(title: "adrag probe", project: project)
        store.update(task.id) { t in
            t.notes = "Call the vendor about the invoice.\nMention the discount."
            t.priority = .high
            t.dueDay = Day.today() + 2
        }
        let openStep = store.addSubtaskNoUndo(task.id, title: "adrag open step")
        let doneStep = store.addSubtaskNoUndo(task.id, title: "adrag done step")
        doneStep?.isDone = true
        model.didMutate()
        guard let live = store.task(task.id) else { record("A-DRAG: probe task exists", false, "missing"); return }

        let provider = DragOut.provider(task: live)
        let types = provider.registeredTypeIdentifiers
        let marker = await dragLoad(provider, DropZonePayloadReader.dragItemTypeID).flatMap { String(data: $0, encoding: .utf8) }
        record("drag out: the private type is first and carries the marker",
               types.first == DropZonePayloadReader.dragItemTypeID && marker == "kronos-task:\(task.id.uuidString)",
               "types=\(types) marker=\(marker ?? "nil")")

        let plain = await dragLoad(provider, DragOut.plainTextType).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let link = TaskLink.string(for: task.id)
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        record("drag out: plain text is the dossier (title, project, priority, deadline, notes, checklist)",
               lines.first == "# adrag probe"
                && plain.contains("Project: adrag.project")
                && plain.contains("Priority: high")
                && plain.contains("Due: \(Day.iso(Day.today() + 2))")
                && plain.contains("Notes:\nCall the vendor about the invoice.\nMention the discount.")
                && plain.contains("- [ ] adrag open step") && plain.contains("- [x] adrag done step")
                && !plain.hasPrefix("kronos-task:"),
               "plain=\(plain)")
        record("drag out: the dossier ends with the kronos://open link",
               lines.last == (breakMode ? link + "x" : link), "last=\(lines.last ?? "nil")")
        _ = openStep

        // What a drop target reads off a pasteboard that holds this provider's representations.
        let pb = adragPasteboard()
        var declared: [NSPasteboard.PasteboardType] = []
        for type in types { declared.append(NSPasteboard.PasteboardType(type)) }
        pb.declareTypes(declared, owner: nil)
        for type in types {
            if let data = await dragLoad(provider, type) { pb.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        }
        record("drag out: Kronos's own drop reader still sees the task row",
               DropZonePayloadReader.read(pb) == .task(task.id), "payload=\(DropZonePayloadReader.read(pb))")
        record("drag out: the in-app attach guard recognises the task drag",
               DropZonePayloadReader.draggedTaskID(from: pb) == task.id, "id=\(String(describing: DropZonePayloadReader.draggedTaskID(from: pb)))")

        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        field.isRichText = false
        let read = field.readSelection(from: pb, type: .string)
        record("drag out: a plain text field (a terminal) receives the whole dossier",
               read && field.string == plain && field.string.contains("adrag open step"),
               "read=\(read) string=\(field.string)")

        // Older clipboards and scripted pasteboards: the marker as plain text still reads as a task.
        let legacy = adragPasteboard()
        legacy.declareTypes([.string], owner: nil)
        legacy.setString(DropZonePayloadReader.taskDragString(task.id), forType: .string)
        record("drag out: the legacy plain-text marker still reads as a task",
               DropZonePayloadReader.read(legacy) == .task(task.id), "payload=\(DropZonePayloadReader.read(legacy))")

        // Dossier text copied out of a terminal and dropped back is text, never a task move.
        let copied = adragPasteboard()
        copied.declareTypes([.string], owner: nil)
        copied.setString(plain, forType: .string)
        let copiedPayload = DropZonePayloadReader.read(copied)
        var isTaskMove = false
        switch copiedPayload { case .task, .subtask: isTaskMove = true; default: break }
        record("drag out: dossier text alone is not mistaken for a task row", !isTaskMove, "payload=\(copiedPayload)")

        // A subtask row keeps its own marker as the first plain text.
        if let child = store.addSubtaskNoUndo(task.id, title: "adrag child") {
            let childProvider = DragOut.provider(id: child.id, title: child.title, isChild: true)
            let text = await dragLoad(childProvider, childProvider.registeredTypeIdentifiers.first ?? "").flatMap { String(data: $0, encoding: .utf8) }
            record("drag out: a subtask row keeps its subtask marker", text == "kronos-subtask:\(child.id.uuidString)", "text=\(text ?? "nil")")
        } else {
            record("drag out: a subtask row keeps its subtask marker", false, "no child created")
        }
    }

    private static func adragPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("kronos.adrag.\(UUID().uuidString)"))
    }

    private static func dragLoad(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in cont.resume(returning: data) }
        }
    }
}
#endif
