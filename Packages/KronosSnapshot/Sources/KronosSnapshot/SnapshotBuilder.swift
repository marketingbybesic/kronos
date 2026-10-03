// SnapshotBuilder.swift — the single producer. Pure: the app hands it the already resolved
// head and shown list; it caps, ellipsises and trims to the byte budget.
//
// Head precedence mirrors the menu bar (MenuBarOrdoController.resolvedFocus): the current
// time block's first open task, else the pin, else the first eligible row of the shown list.

import Foundation

/// Which task is "next" and why. The inputs are ids the caller already resolved from the
/// model; the order here is the only place the precedence lives for the Snapshot.
public enum SnapshotHead {
    public enum Source: String, Sendable { case block, pin, list }

    public struct Resolved: Equatable, Sendable {
        public var taskID: UUID
        public var source: Source
        public var pinned: Bool { source == .pin }
    }

    public static func resolve(blockFocus: UUID?, pin: UUID?, shownHead: UUID?) -> Resolved? {
        if let blockFocus { return Resolved(taskID: blockFocus, source: .block) }
        if let pin { return Resolved(taskID: pin, source: .pin) }
        if let shownHead { return Resolved(taskID: shownHead, source: .list) }
        return nil
    }
}

public struct SnapshotInput {
    public var next: SnapshotItem?
    /// The shown list's eligible rows in order; only the first 8 are kept.
    public var shown: [SnapshotItem]
    public var picker: [SnapshotPickerRow]
    public var smartViews: [SnapshotSmartView]
    public var timeBlocks: [SnapshotTimeBlock]
    public var session: SnapshotSession?
    public var flowRampSeconds: Int
    public var accentHex: String
    public var chroma: Int
    public var undo: SnapshotUndo?

    public init(next: SnapshotItem?, shown: [SnapshotItem], picker: [SnapshotPickerRow] = [],
                smartViews: [SnapshotSmartView] = [], timeBlocks: [SnapshotTimeBlock] = [],
                session: SnapshotSession? = nil, flowRampSeconds: Int = 0, accentHex: String = "",
                chroma: Int = 0, undo: SnapshotUndo? = nil) {
        self.next = next
        self.shown = shown
        self.picker = picker
        self.smartViews = smartViews
        self.timeBlocks = timeBlocks
        self.session = session
        self.flowRampSeconds = flowRampSeconds
        self.accentHex = accentHex
        self.chroma = chroma
        self.undo = undo
    }
}

public enum SnapshotBuilder {
    public static func build(_ input: SnapshotInput, now: Date, calendar: Calendar = .current) -> Snapshot {
        Snapshot(
            generatedAt: now,
            dayNumber: SnapshotDay.number(for: now, calendar: calendar),
            next: input.next.map(capped),
            today: input.shown.prefix(SnapshotLimits.todayMax).map(capped),
            pickerIndex: input.picker.prefix(SnapshotLimits.pickerMax).map {
                SnapshotPickerRow(id: $0.id, title: $0.title.snapshotTrimmed(SnapshotLimits.pickerTitleMax),
                                  projectName: $0.projectName.snapshotTrimmed(SnapshotLimits.projectNameMax))
            },
            smartViews: Array(input.smartViews.prefix(SnapshotLimits.smartViewsMax)),
            timeBlocks: input.timeBlocks,
            session: input.session,
            flowRampSeconds: input.flowRampSeconds,
            accentHex: input.accentHex,
            chroma: input.chroma,
            undo: input.undo)
    }

    private static func capped(_ item: SnapshotItem) -> SnapshotItem {
        var i = item
        i.title = i.title.snapshotTrimmed(SnapshotLimits.titleMax)
        i.firstMove = i.firstMove?.snapshotTrimmed(SnapshotLimits.firstMoveMax)
        return i
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// Serialises under `limit` bytes. Trim order: picker rows from the bottom, then picker
    /// titles shortened to 40 and rows trimmed again, then the whole picker. `next`, `today`
    /// and `session` are never touched.
    public static func encode(_ snapshot: Snapshot, limit: Int = SnapshotLimits.hardLimitBytes) throws -> Data {
        let encoder = makeEncoder()
        var s = snapshot
        var data = try encoder.encode(s)
        if data.count <= limit { return data }

        func fits(_ rows: [SnapshotPickerRow], _ n: Int) throws -> Data? {
            var t = s
            t.pickerIndex = Array(rows.prefix(n))
            let d = try encoder.encode(t)
            return d.count <= limit ? d : nil
        }
        func largestFit(_ rows: [SnapshotPickerRow]) throws -> (Int, Data)? {
            var lo = 0, hi = rows.count
            var best: (Int, Data)?
            while lo <= hi {
                let mid = (lo + hi) / 2
                if let d = try fits(rows, mid) { best = (mid, d); lo = mid + 1 } else { hi = mid - 1 }
            }
            return best
        }

        let minUseful = 50
        if let (n, d) = try largestFit(s.pickerIndex), n >= min(minUseful, s.pickerIndex.count) {
            s.pickerIndex = Array(s.pickerIndex.prefix(n))
            return d
        }
        s.pickerIndex = s.pickerIndex.map {
            SnapshotPickerRow(id: $0.id, title: $0.title.snapshotTrimmed(SnapshotLimits.pickerTitleShort), projectName: $0.projectName)
        }
        if let (n, d) = try largestFit(s.pickerIndex), n >= min(minUseful, s.pickerIndex.count) {
            s.pickerIndex = Array(s.pickerIndex.prefix(n))
            return d
        }
        s.pickerIndex = []
        data = try encoder.encode(s)
        return data
    }
}
