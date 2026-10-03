// SnapshotStore.swift — file IO for Snapshot.json (app process writes, everyone reads) and the
// reader-side display rules (new day, stale, newer contract).

import Foundation

public enum SnapshotWriteResult: Equatable, Sendable {
    /// Content changed: the caller reloads widget timelines / Live Activity / Watch.
    case written
    /// Identical rendered content: nothing written, no reload (reload budget protection).
    case unchanged
}

public final class SnapshotStore: @unchecked Sendable {
    public static let fileName = "Snapshot.json"

    public let directory: URL
    private let lock = NSLock()
    private var last: Snapshot?

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Atomic (temp file + rename). Skips the write when the rendered content equals the
    /// previous snapshot, ignoring `generatedAt`.
    @discardableResult
    public func write(_ snapshot: Snapshot) throws -> SnapshotWriteResult {
        lock.lock(); defer { lock.unlock() }
        let previous = last ?? (try? readRaw())
        if let previous, previous.sameRenderedContent(as: snapshot) {
            last = previous
            return .unchanged
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SnapshotBuilder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        last = snapshot
        return .written
    }

    public func read() -> SnapshotReadResult {
        guard let data = try? Data(contentsOf: fileURL) else { return .missing }
        return SnapshotReader.decode(data)
    }

    private func readRaw() throws -> Snapshot {
        let data = try Data(contentsOf: fileURL)
        return try SnapshotReader.decoder().decode(Snapshot.self, from: data)
    }
}

public enum SnapshotReadResult: Equatable, Sendable {
    case missing
    case unreadable
    /// `v` is newer than this build knows: show the placeholder, never crash.
    case newerContract(Int)
    case snapshot(Snapshot)
}

/// What a reader should draw.
public enum SnapshotDisplay: Equatable, Sendable {
    case live(Snapshot)
    /// Nothing usable (missing, unreadable, newer contract): "Open Kronos".
    case placeholder
    /// Snapshot is from another calendar day: empty state, never yesterday's task.
    case newDay
    /// Older than 24 h but same day: still shown, with the quiet line "Open Kronos to refresh".
    case stale(Snapshot)
}

public enum SnapshotReader {
    public static let staleAfter: TimeInterval = 24 * 3600

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private struct VersionProbe: Decodable { let v: Int }

    public static func decode(_ data: Data) -> SnapshotReadResult {
        let d = decoder()
        guard let probe = try? d.decode(VersionProbe.self, from: data) else { return .unreadable }
        if probe.v > Snapshot.currentVersion { return .newerContract(probe.v) }
        guard let s = try? d.decode(Snapshot.self, from: data) else { return .unreadable }
        return .snapshot(s)
    }

    public static func display(_ result: SnapshotReadResult, now: Date, calendar: Calendar = .current) -> SnapshotDisplay {
        guard case .snapshot(let s) = result else { return .placeholder }
        if s.dayNumber != SnapshotDay.number(for: now, calendar: calendar) { return .newDay }
        if now.timeIntervalSince(s.generatedAt) > staleAfter { return .stale(s) }
        return .live(s)
    }
}
