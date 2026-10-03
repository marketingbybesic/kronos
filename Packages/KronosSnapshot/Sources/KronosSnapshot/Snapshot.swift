// Snapshot.swift — the one document the app process writes for every reader (widgets,
// Live Activity, controls, Share, Watch). Schema version 1. Readers ignore unknown fields;
// a newer `v` than this build knows degrades to a placeholder (SnapshotReader), never a crash.

import Foundation

/// One task as a reader shows it. Titles are ellipsised by the producer (`SnapshotLimits`).
public struct SnapshotItem: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var title: String
    public var firstMove: String?
    /// SF Symbol or bundled asset name.
    public var glyph: String?
    public var projectHex: String?
    /// Only set when the shown list is not Today ("Someday"): the reader shows it as a tiny line.
    public var listLabel: String?
    public var pinned: Bool
    public var done: Bool

    public init(taskID: UUID, title: String, firstMove: String? = nil, glyph: String? = nil,
                projectHex: String? = nil, listLabel: String? = nil, pinned: Bool = false, done: Bool = false) {
        self.taskID = taskID
        self.title = title
        self.firstMove = firstMove
        self.glyph = glyph
        self.projectHex = projectHex
        self.listLabel = listLabel
        self.pinned = pinned
        self.done = done
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decode(UUID.self, forKey: .taskID)
        title = try c.decode(String.self, forKey: .title)
        firstMove = try c.decodeIfPresent(String.self, forKey: .firstMove)
        glyph = try c.decodeIfPresent(String.self, forKey: .glyph)
        projectHex = try c.decodeIfPresent(String.self, forKey: .projectHex)
        listLabel = try c.decodeIfPresent(String.self, forKey: .listLabel)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

/// A row of the Share "Add to task..." picker.
public struct SnapshotPickerRow: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var projectName: String
    public init(id: UUID, title: String, projectName: String) {
        self.id = id
        self.title = title
        self.projectName = projectName
    }
}

public struct SnapshotSmartView: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

public struct SnapshotTimeBlock: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var name: String
    public init(start: Date, end: Date, name: String) { self.start = start; self.end = end; self.name = name }
}

public struct SnapshotSession: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var kind: String
    public var taskID: UUID?
    public var startedAt: Date
    public var plannedMinutes: Int
    public var phase: String
    public init(sessionID: UUID, kind: String, taskID: UUID?, startedAt: Date, plannedMinutes: Int, phase: String) {
        self.sessionID = sessionID
        self.kind = kind
        self.taskID = taskID
        self.startedAt = startedAt
        self.plannedMinutes = plannedMinutes
        self.phase = phase
    }
}

/// An optimistic completion still inside its 5 s undo window.
public struct SnapshotUndo: Codable, Equatable, Sendable {
    public var ticketID: UUID
    public var taskID: UUID
    public var until: Date
    public init(ticketID: UUID, taskID: UUID, until: Date) { self.ticketID = ticketID; self.taskID = taskID; self.until = until }
}

public struct Snapshot: Codable, Equatable, Sendable {
    /// The contract version this build writes and fully understands.
    public static let currentVersion = 1

    public var v: Int
    public var generatedAt: Date
    /// Local calendar day index at generation (see `SnapshotDay`).
    public var dayNumber: Int
    public var next: SnapshotItem?
    /// At most 8, in shown-list order.
    public var today: [SnapshotItem]
    public var pickerIndex: [SnapshotPickerRow]
    public var smartViews: [SnapshotSmartView]
    public var timeBlocks: [SnapshotTimeBlock]
    public var session: SnapshotSession?
    public var flowRampSeconds: Int
    public var accentHex: String
    public var chroma: Int
    public var undo: SnapshotUndo?

    public init(v: Int = Snapshot.currentVersion, generatedAt: Date, dayNumber: Int, next: SnapshotItem? = nil,
                today: [SnapshotItem] = [], pickerIndex: [SnapshotPickerRow] = [], smartViews: [SnapshotSmartView] = [],
                timeBlocks: [SnapshotTimeBlock] = [], session: SnapshotSession? = nil, flowRampSeconds: Int = 0,
                accentHex: String = "", chroma: Int = 0, undo: SnapshotUndo? = nil) {
        self.v = v
        self.generatedAt = generatedAt
        self.dayNumber = dayNumber
        self.next = next
        self.today = today
        self.pickerIndex = pickerIndex
        self.smartViews = smartViews
        self.timeBlocks = timeBlocks
        self.session = session
        self.flowRampSeconds = flowRampSeconds
        self.accentHex = accentHex
        self.chroma = chroma
        self.undo = undo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        dayNumber = try c.decode(Int.self, forKey: .dayNumber)
        next = try c.decodeIfPresent(SnapshotItem.self, forKey: .next)
        today = try c.decodeIfPresent([SnapshotItem].self, forKey: .today) ?? []
        pickerIndex = try c.decodeIfPresent([SnapshotPickerRow].self, forKey: .pickerIndex) ?? []
        smartViews = try c.decodeIfPresent([SnapshotSmartView].self, forKey: .smartViews) ?? []
        timeBlocks = try c.decodeIfPresent([SnapshotTimeBlock].self, forKey: .timeBlocks) ?? []
        session = try c.decodeIfPresent(SnapshotSession.self, forKey: .session)
        flowRampSeconds = try c.decodeIfPresent(Int.self, forKey: .flowRampSeconds) ?? 0
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? ""
        chroma = try c.decodeIfPresent(Int.self, forKey: .chroma) ?? 0
        undo = try c.decodeIfPresent(SnapshotUndo.self, forKey: .undo)
    }

    /// Everything a reader renders, i.e. the snapshot without its timestamp. Identical content
    /// means no widget reload is needed.
    func sameRenderedContent(as other: Snapshot) -> Bool {
        var a = self, b = other
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }
}

/// Producer-side caps.
public enum SnapshotLimits {
    public static let titleMax = 80
    public static let firstMoveMax = 80
    public static let todayMax = 8
    public static let pickerMax = 500
    public static let pickerTitleMax = 60
    public static let pickerTitleShort = 40
    public static let projectNameMax = 24
    public static let smartViewsMax = 4
    /// Hard serialised limit (the plan says under 64 KB).
    public static let hardLimitBytes = 63 * 1024
}

extension String {
    /// Ellipsised to `limit` characters (the ellipsis counts).
    func snapshotTrimmed(_ limit: Int) -> String {
        guard limit > 0, count > limit else { return self }
        return String(prefix(limit - 1)) + "\u{2026}"
    }
}

/// Local calendar day index used to detect a stale day without comparing strings.
public enum SnapshotDay {
    public static func number(for date: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let normalized = utc.date(from: comps) ?? date
        return Int((normalized.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }
}
