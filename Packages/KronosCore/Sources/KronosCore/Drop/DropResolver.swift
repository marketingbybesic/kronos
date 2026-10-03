// KronosCore/Drop/DropResolver.swift
// Turns "the pointer is at y in the list" into one decision: which row, which zone, where the
// insertion line goes and which sibling an insert lands before. Pure: the AppKit overlay feeds it
// the row frames SwiftUI reported, the live UI test feeds it scripted points.
import Foundation

/// One visible row of the list in list coordinates (y grows downwards).
public struct DropRow: Equatable, Sendable {
    public let id: UUID
    /// nil for a task row; the owning task's id for a subtask row.
    public let parentID: UUID?
    public let minY: Double
    public let maxY: Double

    public init(id: UUID, parentID: UUID? = nil, minY: Double, maxY: Double) {
        self.id = id
        self.parentID = parentID
        self.minY = minY
        self.maxY = maxY
    }

    public var kind: DropTargetKind { parentID == nil ? .task : .subtask }
    public var height: Double { maxY - minY }
}

/// What is being dragged, in terms the resolver needs.
public struct DropSubject: Equatable, Sendable {
    public let source: DropSource
    /// The dragged task's or subtask's id; nil for an external drag.
    public let id: UUID?
    /// The dragged subtask's owning task; nil otherwise.
    public let parentID: UUID?

    public init(source: DropSource, id: UUID? = nil, parentID: UUID? = nil) {
        self.source = source
        self.id = id
        self.parentID = parentID
    }

    public static let external = DropSubject(source: .external)
    public static func task(_ id: UUID) -> DropSubject { DropSubject(source: .task, id: id) }
    public static func subtask(_ id: UUID, parent: UUID) -> DropSubject { DropSubject(source: .subtask, id: id, parentID: parent) }
}

/// The ordering the resolver needs to name the sibling an insert lands before. Taken from the
/// whole list, not just the realised rows, so a drop after the last visible row still knows
/// there is a task after it.
public struct DropOrder: Equatable, Sendable {
    /// Level-0 task ids in display order.
    public var tasks: [UUID]
    /// Each task's step ids in display order.
    public var subtasks: [UUID: [UUID]]

    public init(tasks: [UUID], subtasks: [UUID: [UUID]] = [:]) {
        self.tasks = tasks
        self.subtasks = subtasks
    }
}

public struct DropResolution: Equatable, Sendable {
    public let zone: DropZone
    /// The zone the same position would have after the hold; `.none` when nothing waits on it.
    public let heldZone: DropZone
    /// The row the decision is about (for an end-of-list drop: the last task row).
    public let rowID: UUID
    public let rowKind: DropTargetKind
    /// The task the row belongs to: the row itself for a task row, its parent for a subtask row.
    public let taskID: UUID
    /// Insert, nest and move-under zones: the sibling the item lands before; nil means at the end of
    /// that level. Over a child row, nest and move-under land directly after that child.
    public let before: UUID?
    /// Insert zones: the step level (true) or the task level (false) the item lands in.
    public let insertsAmongSubtasks: Bool
    /// Insert zones: y of the insertion line in list coordinates, nil when the line is hidden.
    public let lineY: Double?
    /// Nest / move-under / attach-link: the row to outline, in list coordinates.
    public let highlightMinY: Double
    public let highlightMaxY: Double
    /// True when the drop is past the last row (empty list space).
    public let isEndOfList: Bool

    public init(zone: DropZone, heldZone: DropZone, rowID: UUID, rowKind: DropTargetKind, taskID: UUID,
                before: UUID?, insertsAmongSubtasks: Bool, lineY: Double?,
                highlightMinY: Double, highlightMaxY: Double, isEndOfList: Bool) {
        self.zone = zone
        self.heldZone = heldZone
        self.rowID = rowID
        self.rowKind = rowKind
        self.taskID = taskID
        self.before = before
        self.insertsAmongSubtasks = insertsAmongSubtasks
        self.lineY = lineY
        self.highlightMinY = highlightMinY
        self.highlightMaxY = highlightMaxY
        self.isEndOfList = isEndOfList
    }
}

public enum DropResolver {
    /// - Parameters:
    ///   - rows: the realised rows, top to bottom.
    ///   - pointerY: pointer y in the same coordinates as the rows.
    ///   - subject: what is dragged.
    ///   - order: full display order (see `DropOrder`).
    ///   - holdSeconds: how long the pointer has rested in the middle of the current row.
    ///   - isManualSort: the list's sort is manual order.
    /// - Returns: nil when there are no rows to decide against.
    public static func resolve(rows: [DropRow], pointerY: Double, subject: DropSubject, order: DropOrder,
                               holdSeconds: TimeInterval, isManualSort: Bool) -> DropResolution? {
        guard let first = rows.first, let last = rows.last else { return nil }

        // Past the last row: empty list space. External items and moved items go to the end of
        // the level-0 list; a step dropped here is promoted to level 0 at the end.
        // Only when the last realised row really belongs to the last task: a lazily unrealised
        // tail must not be mistaken for the end.
        if pointerY > last.maxY, let lastTask = order.tasks.last, (last.parentID ?? last.id) == lastTask {
            return endOfList(lastTask: lastTask, lastRow: last, subject: subject, isManualSort: isManualSort)
        }

        let row = rowNearest(to: pointerY, in: rows, first: first)
        let y = min(max(pointerY - row.minY, 0), row.height)
        let taskID = row.parentID ?? row.id

        // A dragged item is never a target for itself or for what belongs to it.
        let ownBlock: Bool = {
            switch subject.source {
            case .task: return subject.id == taskID
            case .subtask: return subject.id == row.id
            case .external: return false
            }
        }()
        let sameFamily = subject.source == .subtask && subject.parentID == taskID

        func zone(hold: TimeInterval) -> DropZone {
            if ownBlock { return .none }
            return DropRules.zone(pointerY: y, rowHeight: row.height, target: row.kind, source: subject.source,
                                  sameFamily: sameFamily, holdSeconds: hold, isManualSort: isManualSort)
        }
        let now = zone(hold: holdSeconds)
        let held = zone(hold: dropHoldSeconds)

        let among = row.kind == .subtask
        var before: UUID? = nil
        var lineY: Double? = nil
        if now.isInsert {
            before = insertBefore(row: row, zone: now, order: order)
            if DropRules.showsInsertionLine(zone: now, target: row.kind, isManualSort: isManualSort) {
                lineY = now == .insertAbove ? row.minY : row.maxY
            }
        }
        if now == .nest || now == .moveUnder, row.kind == .subtask {
            before = insertBefore(row: row, zone: .insertBelow, order: order)
        }
        return DropResolution(zone: now, heldZone: held == now ? .none : held, rowID: row.id, rowKind: row.kind,
                              taskID: taskID, before: before, insertsAmongSubtasks: among, lineY: lineY,
                              highlightMinY: row.minY, highlightMaxY: row.maxY, isEndOfList: false)
    }

    private static func endOfList(lastTask: UUID, lastRow: DropRow, subject: DropSubject,
                                  isManualSort: Bool) -> DropResolution {
        // A level-0 move means nothing in a sorted list; creating a task or promoting a step still lands at the end.
        let own = (subject.source == .task && subject.id == lastTask) || (subject.source == .task && !isManualSort)
        let zone: DropZone = own ? .none : .insertBelow
        let shown = zone == .insertBelow && isManualSort
        return DropResolution(zone: zone, heldZone: .none, rowID: lastTask, rowKind: .task, taskID: lastTask,
                              before: nil, insertsAmongSubtasks: false, lineY: shown ? lastRow.maxY : nil,
                              highlightMinY: lastRow.minY, highlightMaxY: lastRow.maxY, isEndOfList: true)
    }

    /// The row the pointer belongs to: the one it is inside, else the nearer neighbour across a gap.
    private static func rowNearest(to y: Double, in rows: [DropRow], first: DropRow) -> DropRow {
        if y <= first.minY { return first }
        var previous = first
        for row in rows {
            if y >= row.minY && y <= row.maxY { return row }
            if y < row.minY {
                // In the gap between `previous` and `row`.
                return (y - previous.maxY) <= (row.minY - y) ? previous : row
            }
            previous = row
        }
        return previous
    }

    private static func insertBefore(row: DropRow, zone: DropZone, order: DropOrder) -> UUID? {
        if row.kind == .task {
            if zone == .insertAbove { return row.id }
            guard let i = order.tasks.firstIndex(of: row.id), i + 1 < order.tasks.count else { return nil }
            return order.tasks[i + 1]
        }
        if zone == .insertAbove { return row.id }
        guard let parent = row.parentID, let siblings = order.subtasks[parent],
              let i = siblings.firstIndex(of: row.id), i + 1 < siblings.count else { return nil }
        return siblings[i + 1]
    }
}
