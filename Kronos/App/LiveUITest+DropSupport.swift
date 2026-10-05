// Kronos/App/LiveUITest+DropSupport.swift — helpers of the drop-engine live steps (LiveUITest+Drop.swift):
// the scripted drag session, the pointer script runner, snapshots of the store, named private
// pasteboards (never the person's clipboard or the system drag pasteboard) and a hand-made Envelope
// Index. Compiled only outside Release.
#if !RELEASE
import AppKit
import SQLite3
import KronosCore

/// A scripted stand-in for the session AppKit would hand the destination.
final class ScriptedDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    var location: NSPoint
    let window: NSWindow
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        self.pasteboard = pasteboard
        self.location = location
        self.window = window
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor
extension LiveUITest {
    // MARK: - Driving

    struct DragResult { var accepted: Bool; var dropped: Bool }

    /// Enter, move through the stops (dwelling at each), then hover / drop / cancel.
    static func drag(_ model: AppModel, _ pasteboard: NSPasteboard, _ stops: [DropStop], end: DropEnd) async -> DragResult {
        guard let overlay = ListDropOverlayView.live, let first = stops.first, let p0 = windowPoint(first.anchor, y: first.y) else {
            return DragResult(accepted: false, dropped: false)
        }
        UndoToastCenter.shared.dismiss()
        let info = ScriptedDraggingInfo(pasteboard: pasteboard, location: p0, window: window)
        activeInfo = info
        let entered = overlay.draggingEntered(info)
        var accepted = !entered.isEmpty
        for stop in stops {
            guard let p = windowPoint(stop.anchor, y: stop.y) else { continue }
            info.location = p
            accepted = !overlay.draggingUpdated(info).isEmpty
            try? await Task.sleep(for: .milliseconds(stop.dwellMs))
        }
        switch end {
        case .hover:
            return DragResult(accepted: accepted, dropped: false)
        case .cancel:
            overlay.draggingExited(info)
            return DragResult(accepted: accepted, dropped: false)
        case .drop:
            let dropped = await finish(overlay, overlay.controller!, model, pasteboard, end: .drop)
            return DragResult(accepted: accepted, dropped: dropped)
        }
    }

    /// Ends the drag started by the last `drag(..., end: .hover)` at its current position.
    @discardableResult
    static func finish(_ overlay: ListDropOverlayView, _ controller: ListDropController, _ model: AppModel,
                               _ pasteboard: NSPasteboard, end: DropEnd) async -> Bool {
        guard let info = activeInfo else { return false }
        _ = overlay.draggingUpdated(info)   // the final position, hold measured up to now
        let ready = overlay.prepareForDragOperation(info)
        let dropped = ready && overlay.performDragOperation(info)
        overlay.concludeDragOperation(info)
        overlay.draggingEnded(info)
        activeInfo = nil
        try? await Task.sleep(for: .milliseconds(250))
        return dropped
    }

    nonisolated(unsafe) static var activeInfo: ScriptedDraggingInfo?

    static func settle() async { try? await Task.sleep(for: .milliseconds(450)) }

    /// Rows only show their steps while expanded; a rebuilt row (after an undo) starts collapsed.
    static func expandAll() async {
        NotificationCenter.default.post(name: .kronosExpandAllSubtasks, object: true)
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// Window coordinates of a point `y` (0...1) down the anchored row.
    static func windowPoint(_ anchor: String, y: CGFloat) -> NSPoint? {
        guard let f = UITestAnchors.frames[anchor], f.height > 1, let content = window.contentView else { return nil }
        let x = f.minX + 80
        let gy = f.minY + f.height * y
        let local = content.isFlipped ? NSPoint(x: x, y: gy) : NSPoint(x: x, y: content.bounds.height - gy)
        return content.convert(local, to: nil)
    }

    static func overlayWindowPoint(_ overlay: ListDropOverlayView, x: CGFloat, y: CGFloat) -> NSPoint {
        overlay.convert(NSPoint(x: x, y: y), to: nil)
    }

    // MARK: - Snapshots

    static func titles(_ model: AppModel, _ project: KProject) -> [String] {
        KTaskSorter.sorted(model.store.allTasks().filter { $0.project?.id == project.id && !$0.title.hasPrefix("dnd.bulk") }, by: [.asc(.manual)]).map(\.title)
    }

    /// Everything an exact undo must restore: ids, order values, state, notes, and every step.
    static func snapshot(_ model: AppModel, _ project: KProject) -> Snapshot {
        var lines: [String] = []
        for task in model.store.allTasks() where task.project?.id == project.id {
            lines.append("T|\(task.id)|\(task.title)|\(task.sortIndex)|\(task.statusRaw)|\(task.dueDay.map(String.init) ?? "-")|\(task.priorityRaw)|\(task.notes)|\(task.recurrenceRule ?? "-")|\(task.calendarEventID ?? "-")")
            for s in task.orderedSubtasks {
                lines.append("S|\(s.id)|\(task.id)|\(s.title)|\(s.sortIndex)|\(s.isDone)|\(s.dueDay.map(String.init) ?? "-")|\(s.priorityRaw)|\(s.notes)")
            }
        }
        return Snapshot(lines: lines.sorted())
    }

    // MARK: - Pasteboards (named, private: never the person's clipboard or the system drag pasteboard)

    static func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("kronos.uitest.drop.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    static func internalTaskPasteboard(_ key: String, _ tasks: [String: KTask]) -> NSPasteboard {
        // The shape a real task-row drag has: the private marker type, and plain text that is
        // NOT the marker (a dossier), so these steps prove the reader no longer needs plain text.
        let pb = freshPasteboard()
        let task = tasks[key]!
        pb.declareTypes([DropZonePayloadReader.dragItemType, .string], owner: nil)
        pb.setData(Data(DropZonePayloadReader.taskDragString(task.id).utf8), forType: DropZonePayloadReader.dragItemType)
        pb.setString("# \(task.title)\n\n" + TaskLink.string(for: task.id), forType: .string)
        return pb
    }

    static func internalTask(_ key: String, _ tasks: [String: KTask]) -> NSPasteboard { internalTaskPasteboard(key, tasks) }

    static func internalSubtask(_ s: KTask, _ parent: KTask) -> NSPasteboard {
        let pb = freshPasteboard()
        pb.setString(DropZonePayloadReader.subtaskDragString(s.id), forType: .string)
        return pb
    }

    static func mailPasteboard(url: String, subject: String?) -> NSPasteboard {
        let pb = freshPasteboard()
        let item = NSPasteboardItem()
        item.setString(url, forType: .URL)
        if let subject {
            item.setString(subject, forType: NSPasteboard.PasteboardType("public.url-name"))
            item.setString(subject, forType: .string)
        }
        pb.writeObjects([item])
        return pb
    }

    static func filePasteboard(_ urls: [URL]) -> NSPasteboard {
        let pb = freshPasteboard()
        pb.writeObjects(urls.map { $0 as NSURL })
        return pb
    }

    static func notesPasteboard(text: String) -> NSPasteboard {
        let pb = freshPasteboard()
        let item = NSPasteboardItem()
        item.setData(Data("note".utf8), forType: NSPasteboard.PasteboardType("com.apple.notes.note"))
        item.setString(text, forType: .string)
        pb.writeObjects([item])
        return pb
    }

    static func textPasteboard(_ text: String) -> NSPasteboard {
        let pb = freshPasteboard()
        pb.setString(text, forType: .string)
        return pb
    }
}

/// A tiny stand-in for Mail's Envelope Index with just the three tables the lookup reads.
enum EnvelopeIndexFixture {
    static func build(at path: String, messageID: String, subject: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }
        let statements = [
            "CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT)",
            "CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT)",
            "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, global_message_id INTEGER, subject INTEGER)",
            "INSERT INTO subjects VALUES (7, '\(subject)')",
            "INSERT INTO message_global_data VALUES (3, '\(messageID)')",
            "INSERT INTO messages VALUES (1, 3, 7)",
        ]
        for sql in statements where sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { return false }
        return true
    }
}
#endif
