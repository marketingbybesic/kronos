// Kronos/List/DropZoneController.swift
// The drag-and-drop engine of the middle list. ONE object per list: the AppKit overlay
// (DropOverlayView) forwards every drag callback here, SwiftUI reports the row frames into it, and
// the indicators (DropZoneIndicators) draw whatever `feedback` says. All decisions come from the
// pure rules in KronosCore (DropResolver / DropPlanner); this file owns the things that are not
// pure: the 0.6 s hold timer, auto-scroll, the nest guard lookup against the store, and the
// pointer bookkeeping. Committing a drop lives in DropZoneCommit.swift.
import AppKit
import Observation
import KronosCore

/// A row's frame in the list container's coordinate space (top-left origin, scrolled viewport).
struct DropRowFrame: Equatable {
    let id: UUID
    let parentID: UUID?
    let frame: CGRect
}

/// What the list currently shows about the drag in progress.
struct DropFeedback: Equatable {
    enum Hint: Equatable {
        case nest
        case moveUnder
        case attachLink
        case newTask
        /// A step dropped between tasks becomes a task (shown when no insertion line is drawn).
        case promote
    }

    var resolution: DropResolution
    /// Frame of the row the decision is about; nil when it scrolled out of the realised rows.
    var rowFrame: CGRect?
    var hint: Hint?
    /// Insertion line extent (list x), nil when no line is drawn.
    var lineX0: CGFloat = 0
    var lineX1: CGFloat = 0
}

/// What the list hands the engine on every update: the order of things on screen and the sort mode.
struct ListDropConfig: Equatable {
    var order: DropOrder
    /// Visible task ids in manual order (equals `order.tasks` when the list is manual).
    var manualOrder: [UUID]
    var isManualSort: Bool
    var scope: ListScope
}

@MainActor
@Observable
final class ListDropController {
    // MARK: Observed by the indicators
    private(set) var feedback: DropFeedback?
    /// A refusal that stays on screen for a moment after a blocked drop.
    private(set) var toast: String?

    // MARK: Engine state (not observed)
    @ObservationIgnored let model: AppModel
    @ObservationIgnored var config = ListDropConfig(order: DropOrder(tasks: []), manualOrder: [], isManualSort: true, scope: .all)
    @ObservationIgnored private(set) var rows: [DropRow] = []
    @ObservationIgnored private var frames: [UUID: DropRowFrame] = [:]
    @ObservationIgnored private(set) var payload: DropPayload = .unsupported
    @ObservationIgnored private(set) var subject: DropSubject?
    @ObservationIgnored private var pointer: CGPoint?
    var lastPointer: CGPoint? { pointer }
    @ObservationIgnored private var viewHeight: CGFloat = 0
    @ObservationIgnored private var holdRow: UUID?
    @ObservationIgnored private var holdStart: TimeInterval?
    @ObservationIgnored private var holdTimer: Timer?
    @ObservationIgnored private var scrollTimer: Timer?
    @ObservationIgnored private var toastTimer: Timer?
    /// Scrolls the list by this many points (set by the AppKit overlay). Positive scrolls down.
    @ObservationIgnored var scroller: ((CGFloat) -> Void)?
    /// True while a drag is over the list.
    @ObservationIgnored private(set) var isActive = false
    /// The clock the hold is measured on; replaceable only so a test could shorten waiting.
    @ObservationIgnored var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Fed by SwiftUI

    func setRowFrames(_ list: [DropRowFrame]) {
        frames = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        rows = list.filter { $0.frame.height > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { DropRow(id: $0.id, parentID: $0.parentID, minY: Double($0.frame.minY), maxY: Double($0.frame.maxY)) }
        // Rows moved under a resting pointer (scrolling, list changes). Deferred: this runs while SwiftUI lays out.
        if isActive {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { if self?.isActive == true { self?.refresh() } }
            }
        }
    }

    func frame(of id: UUID) -> CGRect? { frames[id]?.frame }

    // MARK: Drag lifecycle

    /// A drag entered the list. Returns false when nothing in it can be dropped here.
    @discardableResult
    func begin(_ payload: DropPayload) -> Bool {
        endSession()
        self.payload = payload
        subject = payload.subject(model: model)
        isActive = subject != nil
        return isActive
    }

    /// The pointer moved (or rests): `point` in list coordinates, top-left origin. Returns whether
    /// a drop here would be accepted (now, or once the hold has run).
    @discardableResult
    func update(pointer point: CGPoint, viewHeight height: CGFloat) -> Bool {
        guard isActive else { return false }
        pointer = point
        viewHeight = height
        let accepted = refresh()
        updateAutoScroll()
        return accepted
    }

    /// The drag left, was cancelled (Esc) or ended: nothing changes, indicators disappear.
    func end() {
        endSession()
    }

    // MARK: Resolution

    var currentResolution: DropResolution? { feedback?.resolution }

    /// Where the pointer is and what a drop there would do, with the hold measured on `now`.
    func resolution(forPointer p: CGPoint) -> DropResolution? {
        guard let subject else { return nil }
        // The hold belongs to the row whose centre the pointer rests in: probe with an endless hold.
        let probe = DropResolver.resolve(rows: rows, pointerY: Double(p.y), subject: subject, order: config.order,
                                         holdSeconds: .infinity, isManualSort: config.isManualSort)
        let candidate = (probe?.zone.needsHold == true) ? probe?.rowID : nil
        if candidate != holdRow {
            holdRow = candidate
            holdStart = candidate == nil ? nil : now()
            scheduleHoldTimer(active: candidate != nil)
        }
        let held = holdStart.map { now() - $0 } ?? 0
        return DropResolver.resolve(rows: rows, pointerY: Double(p.y), subject: subject, order: config.order,
                                    holdSeconds: held, isManualSort: config.isManualSort)
    }

    /// Recomputes `feedback` from the last pointer. True when a drop would be accepted now or
    /// after the hold.
    @discardableResult
    private func refresh() -> Bool {
        guard let p = pointer, let r = resolution(forPointer: p) else {
            setFeedback(nil)
            return false
        }
        // Nest and move-under outline the TASK that receives the item, even when the pointer is over one of its steps.
        let outlined = (r.zone == .nest || r.zone == .moveUnder) ? r.taskID : r.rowID
        var f = DropFeedback(resolution: r, rowFrame: frames[outlined]?.frame ?? frames[r.rowID]?.frame, hint: nil)
        switch r.zone {
        case .nest: f.hint = .nest
        case .moveUnder: f.hint = .moveUnder
        case .attachLink: f.hint = .attachLink
        case .insertAbove, .insertBelow:
            if subject?.source == .external { f.hint = .newTask }
            else if subject?.source == .subtask, !r.insertsAmongSubtasks { f.hint = .promote }
            if r.lineY != nil, let rowFrame = frames[r.rowID]?.frame ?? endRowFrame(r) {
                let indent: CGFloat = r.insertsAmongSubtasks ? Self.subtaskIndent : 0
                f.lineX0 = rowFrame.minX + indent
                f.lineX1 = rowFrame.maxX
            }
        case .none: break
        }
        setFeedback(f)
        return r.zone != .none || r.heldZone != .none
    }

    private func endRowFrame(_ r: DropResolution) -> CGRect? {
        frames[r.rowID]?.frame ?? rows.last.map { CGRect(x: 0, y: $0.minY, width: 0, height: $0.height) }
    }

    private func setFeedback(_ f: DropFeedback?) {
        if feedback != f { feedback = f }
    }

    /// Indent of a step row's content, so the insertion line of a step starts under its text.
    static var subtaskIndent: CGFloat { Metrics.listRowLeading + Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap }

    // MARK: Hold timer (a real Timer: draggingUpdated fires only on movement)

    private func scheduleHoldTimer(active: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard active else { return }
        let timer = Timer(timeInterval: dropHoldSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)   // .common: also fires while a drag tracks the run loop
        holdTimer = timer
    }

    private func holdElapsed() {
        holdTimer = nil
        guard isActive else { return }
        refresh()
    }

    // MARK: Auto-scroll

    private func updateAutoScroll() {
        guard let p = pointer, scroller != nil,
              DropAutoScroll.step(pointerY: Double(p.y), viewHeight: Double(viewHeight)) != 0 else {
            scrollTimer?.invalidate()
            scrollTimer = nil
            return
        }
        guard scrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func scrollTick() {
        guard isActive, let p = pointer else { return }
        let step = DropAutoScroll.step(pointerY: Double(p.y), viewHeight: Double(viewHeight))
        guard step != 0 else { scrollTimer?.invalidate(); scrollTimer = nil; return }
        scroller?(CGFloat(step))
        refresh()
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toast = text
        toastTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.toast = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        toastTimer = timer
    }

    // MARK: Teardown

    private func endSession() {
        holdTimer?.invalidate(); holdTimer = nil
        scrollTimer?.invalidate(); scrollTimer = nil
        holdRow = nil
        holdStart = nil
        pointer = nil
        isActive = false
        subject = nil
        payload = .unsupported
        setFeedback(nil)
    }
}
