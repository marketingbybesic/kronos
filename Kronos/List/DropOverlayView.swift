// Kronos/List/DropOverlayView.swift
// The ONE drop destination of the middle list: an AppKit view laid over the list's scroll view.
// Why AppKit and why one view: SwiftUI's per-row drop modifiers cannot see an Apple Notes drag
// (its private note type is not public.item), cannot tell where between two rows the pointer is,
// and fire nothing while the pointer rests. This view registers for every type Kronos can use,
// forwards each callback to ListDropController, and stays invisible to the mouse: clicks, scrolls
// and hovers fall through to the rows below because `hitTest` only answers while a drag is live.
import AppKit
import SwiftUI
import KronosCore

final class ListDropOverlayView: NSView {
    weak var controller: ListDropController?
    private weak var cachedScrollView: NSScrollView?

    /// The overlay currently mounted in the main window (the live UI test drives it).
    nonisolated(unsafe) static weak var live: ListDropOverlayView?
    /// Test switch: answer hit tests as if a drag were live.
    nonisolated(unsafe) static var forceDragHitTesting = false

    static let registeredTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [
            .string, .URL, .fileURL, .html, .rtf, .rtfd, .tiff, .png, .pdf,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("public.item"),
            NSPasteboard.PasteboardType("public.data"),
            NSPasteboard.PasteboardType("public.content"),
            NSPasteboard.PasteboardType("public.composite-content"),
            NSPasteboard.PasteboardType("public.url-name"),
            NSPasteboard.PasteboardType("com.apple.mail.message"),
            NSPasteboard.PasteboardType("com.apple.notes.note"),
            NSPasteboard.PasteboardType("com.apple.notes.richtext"),
            NSPasteboard.PasteboardType("Apple URL pasteboard type"),
        ]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return types
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.registeredTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: Invisible to everything but drags

    /// A drag session holds the left button down and is not the mouse-down that starts a click;
    /// every other event (clicks, right clicks, scrolls, hovers, keys) must reach the rows.
    static var dragIsLive: Bool {
        if forceDragHitTesting { return true }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        return NSApp.currentEvent?.type != .leftMouseDown
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Self.dragIsLive else { return nil }
        return super.hitTest(point)
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let controller else { return [] }
        if ListDropController.debugLogEnabled { DropTypesLog.append(sender.draggingPasteboard, event: "entered") }
        guard controller.begin(DropZonePayloadReader.read(sender.draggingPasteboard)) else { return [] }
        return track(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let controller, controller.isActive else { return [] }
        return track(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.end()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.isActive == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller, controller.isActive else { return false }
        _ = track(sender)   // the final position, with the hold measured up to the drop
        return controller.perform()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.end()
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let controller else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let accepted = controller.update(pointer: point, viewHeight: bounds.height)
        guard accepted else { return [] }
        return Self.operation(for: controller.payload, mask: sender.draggingSourceOperationMask)
    }

    /// Move for Kronos's own rows, copy for everything coming from another app.
    static func operation(for payload: DropPayload, mask: NSDragOperation) -> NSDragOperation {
        let preference: [NSDragOperation]
        switch payload {
        case .task, .subtask: preference = [.move, .generic, .copy]
        default: preference = [.copy, .generic, .link, .move]
        }
        return preference.first { mask.contains($0) } ?? []
    }

    // MARK: Auto-scroll target

    /// The scroll view the list lives in: the one under this overlay with the largest overlap.
    func listScrollView() -> NSScrollView? {
        if let cached = cachedScrollView, cached.window === window { return cached }
        cachedScrollView = nil
        guard let content = window?.contentView else { return nil }
        let mine = convert(bounds, to: nil)
        var best: (NSScrollView, CGFloat)?
        func visit(_ view: NSView) {
            if let sv = view as? NSScrollView, sv.documentView != nil {
                let overlap = sv.convert(sv.bounds, to: nil).intersection(mine)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > (best?.1 ?? 0) { best = (sv, area) }
            }
            view.subviews.forEach(visit)
        }
        visit(content)
        cachedScrollView = best?.0
        return best?.0
    }

    func scroll(by delta: CGFloat) {
        guard let sv = listScrollView(), let doc = sv.documentView else { return }
        let clip = sv.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(origin.y + (doc.isFlipped ? delta : -delta), 0), maxY)
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        sv.reflectScrolledClipView(clip)
    }
}

/// Mounts the overlay over the list and hands the engine the current order and sort mode.
struct ListDropOverlay: NSViewRepresentable {
    let controller: ListDropController
    let config: ListDropConfig

    func makeNSView(context: Context) -> ListDropOverlayView {
        let view = ListDropOverlayView()
        view.controller = controller
        controller.config = config
        controller.scroller = { [weak view] delta in view?.scroll(by: delta) }
        ListDropOverlayView.live = view
        return view
    }

    func updateNSView(_ view: ListDropOverlayView, context: Context) {
        view.controller = controller
        controller.config = config
        ListDropOverlayView.live = view
    }

    static func dismantleNSView(_ view: ListDropOverlayView, coordinator: ()) {
        if ListDropOverlayView.live === view { ListDropOverlayView.live = nil }
        view.controller?.end()
    }
}

extension ListDropController {
    /// Logs the type names of every drag that enters the list (Debug builds always; Release only
    /// with `defaults write <bundle id> kronos.dropLog -bool YES`).
    static var debugLogEnabled: Bool {
        #if RELEASE
        return UserDefaults.standard.bool(forKey: "kronos.dropLog")
        #else
        return true
        #endif
    }
}
