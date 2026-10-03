// KronosCore/Drop/DropZone.swift
// The pure rule of the list drag-and-drop engine: where on a row the pointer is, what is being
// dragged and for how long the pointer has rested decide what a drop there would do. No AppKit,
// no SwiftUI, no store: the AppKit overlay and the live UI test both feed it plain numbers, and
// the hand-written table in DropZoneTests pins every combination.
import Foundation

/// How long the pointer must rest on the middle of a row before nest / move-under / attach-link
/// becomes available. The ONE place this number lives.
public let dropHoldSeconds: TimeInterval = 0.6

/// Share of a row's height, at the top and at the bottom, that counts as its edge. Edges mean
/// "between rows" (insert); what is left in the middle means "onto this row".
public let dropEdgeFraction: Double = 0.25

/// What is being dragged.
public enum DropSource: Equatable, Sendable {
    /// A level-0 task from this list.
    case task
    /// A subtask (step) from this list.
    case subtask
    /// Something from another app: a Mail message, a Finder file, a Notes note.
    case external
}

/// What kind of row the pointer is over.
public enum DropTargetKind: Equatable, Sendable {
    case task
    case subtask
}

/// What a drop at this position would do.
public enum DropZone: Equatable, Sendable {
    /// Insert before the row (reorder, promote to level 0, create a task, or reorder steps).
    case insertAbove
    /// Insert after the row.
    case insertBelow
    /// A task becomes a subtask of the row's task (needs the hold).
    case nest
    /// A subtask moves under the row's task (needs the hold).
    case moveUnder
    /// An external item is attached as a link to the row (needs the hold).
    case attachLink
    /// Nothing happens here.
    case none

    public var isInsert: Bool { self == .insertAbove || self == .insertBelow }
    /// True for the zones that only become available after the hold.
    public var needsHold: Bool { self == .nest || self == .moveUnder || self == .attachLink }
}

public enum DropBand: Equatable, Sendable {
    case top, centre, bottom
}

public enum DropRules {
    /// Top edge, centre or bottom edge for a pointer `y` points below the top of a row that is
    /// `rowHeight` tall. A pointer outside the row counts as the nearest edge.
    public static func band(pointerY y: Double, rowHeight: Double) -> DropBand {
        guard rowHeight > 0 else { return .centre }
        let edge = rowHeight * dropEdgeFraction
        if y < edge { return .top }
        if y > rowHeight - edge { return .bottom }
        return .centre
    }

    /// The zone for one pointer position.
    /// - Parameters:
    ///   - pointerY: pointer y measured from the top of the row.
    ///   - rowHeight: height of the row under the pointer.
    ///   - target: task row or subtask row.
    ///   - source: what is being dragged.
    ///   - sameFamily: the dragged subtask belongs to the task this row is, or is, a subtask of.
    ///     Only read for a dragged subtask.
    ///   - holdSeconds: how long the pointer has rested in this row's middle.
    ///   - isManualSort: whether the list is in manual order (level-0 order is user-defined).
    public static func zone(pointerY: Double, rowHeight: Double, target: DropTargetKind,
                            source: DropSource, sameFamily: Bool = false,
                            holdSeconds: TimeInterval, isManualSort: Bool) -> DropZone {
        let band = band(pointerY: pointerY, rowHeight: rowHeight)
        let held = holdSeconds >= dropHoldSeconds
        switch (source, target) {
        case (.task, .task):
            switch band {
            case .top: return isManualSort ? .insertAbove : .none
            case .bottom: return isManualSort ? .insertBelow : .none
            case .centre: return held ? .nest : .none
            }
        case (.task, .subtask):
            // Between a task's steps is no place for a task: only the nest-under-the-parent
            // gesture is offered here.
            return band == .centre && held ? .nest : .none
        case (.subtask, .task):
            switch band {
            case .top: return .insertAbove
            case .bottom: return .insertBelow
            case .centre: return held && !sameFamily ? .moveUnder : .none
            }
        case (.subtask, .subtask):
            switch band {
            case .top: return .insertAbove
            case .bottom: return .insertBelow
            case .centre: return held && !sameFamily ? .moveUnder : .none
            }
        case (.external, .task):
            switch band {
            case .top: return .insertAbove
            case .bottom: return .insertBelow
            case .centre: return held ? .attachLink : .none
            }
        case (.external, .subtask):
            return band == .centre && held ? .attachLink : .none
        }
    }

    /// Whether the accent insertion line is drawn for an insert zone. A level-0 position means
    /// nothing while the list is sorted by something other than manual order, so the line is
    /// hidden there (the drop still works: the task lands where the sort puts it). Subtask
    /// order is always manual, so its line is always drawn.
    public static func showsInsertionLine(zone: DropZone, target: DropTargetKind, isManualSort: Bool) -> Bool {
        guard zone.isInsert else { return false }
        return target == .subtask || isManualSort
    }
}

/// Auto-scroll while a drag rests near the top or bottom edge of the list.
public enum DropAutoScroll {
    /// Height of the sensitive band at each edge, in points.
    public static let edge: Double = 48
    /// Points scrolled per tick (60 per second) with the pointer on the very edge.
    public static let maxStep: Double = 18

    /// Points to scroll this tick: negative scrolls up, positive down, 0 away from the edges or in a
    /// view too short to have two bands. Speed grows linearly towards the edge.
    public static func step(pointerY: Double, viewHeight: Double) -> Double {
        guard viewHeight > edge * 2 else { return 0 }
        if pointerY < edge {
            let depth = (edge - max(pointerY, 0)) / edge
            return -max(2, maxStep * depth)
        }
        if pointerY > viewHeight - edge {
            let depth = (edge - max(viewHeight - pointerY, 0)) / edge
            return max(2, maxStep * depth)
        }
        return 0
    }
}
