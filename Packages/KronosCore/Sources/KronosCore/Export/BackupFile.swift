import Foundation

/// Read/write helpers for the daily auto-backup (§10.2, D22:
/// `~/Library/Application Support/Kronos/backups/`, keep 14). Settings calls
/// this rather than hand-rolling file I/O so the write is always atomic and
/// the read always sanity-checked before it reaches an importer.
public enum BackupFile {
    public enum ReadError: Error, LocalizedError {
        case empty
        case notJSON
        case missingFormatField
        case wrongFormat(String)

        // GAP: unreachable from the UI, same as StoreError.errorDescription's note —
        // SettingsDataTab's import catch block always shows the generic
        // settings.data.import.failed catalog string instead of reading this.
        public var errorDescription: String? {
            switch self {
            case .empty: return "Backup file is empty."
            case .notJSON: return "Backup file is not valid JSON."
            case .missingFormatField: return "Backup file is missing its format marker."
            case .wrongFormat(let f): return "\"\(f)\" is not a Kronos backup."
            }
        }
    }

    /// Atomic write: `Data.write(options: .atomic)` writes to a temp file in
    /// the same directory and renames it over the target, so a crash or a
    /// full disk mid-write never leaves a half-written backup on disk. The
    /// envelope holds full plaintext task titles/notes, so the file is
    /// locked to the person only — 0600 — the same explicit lockdown
    /// `SingleInstanceLock.acquire` applies to its own lock file.
    public static func write(_ envelope: KronosExportEnvelope, to url: URL) throws {
        let data = try KronosExportCodec.makeEncoder().encode(envelope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Read and sanity-check without fully decoding into models: cheap
    /// enough to run before showing "Restore from backup" a file's summary.
    public static func read(from url: URL) throws -> KronosExportEnvelope {
        let data = try Data(contentsOf: url)
        try sanityCheck(data)
        return try KronosExportCodec.makeDecoder().decode(KronosExportEnvelope.self, from: data)
    }

    /// Size/version sanity checks a caller can run before committing to a
    /// full decode — an empty file, a non-JSON file, or a file from some
    /// other app should fail with a clear reason rather than a raw decoder
    /// error.
    public static func sanityCheck(_ data: Data) throws {
        guard !data.isEmpty else { throw ReadError.empty }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.notJSON
        }
        guard let format = obj["format"] as? String else { throw ReadError.missingFormatField }
        guard format == "kronos" else { throw ReadError.wrongFormat(format) }
    }
}

/// Pure rules for the backups folder: what to prune, when the rolling copy is due, and how old the
/// newest backup is. No file or clock access here, so a table of cases decides every outcome.
public enum BackupPolicy {
    /// The rolling copy, overwritten on resign-active and on quit. Never pruned.
    public static let rollingStoreName = "kronos-today.store"
    /// A backup older than this many days earns the calm warning in Settings > Data.
    public static let staleAfterDays = 3
    /// Daily files (`kronos-yyyy-MM-dd.json` / `.store`) kept per extension.
    public static let dailyKeep = 14
    /// Files written before a risky step. Pruned by age, but the newest few always stay.
    public static let safetyPrefixes = ["pre-restore-", "pre-import-", "crash-", "emergency-", "pre-purge-"]
    public static let safetyKeepNewest = 3
    public static let safetyMaxAge: TimeInterval = 30 * 86_400
    /// A leftover `.partial` (an interrupted snapshot) is removed after a day.
    public static let partialMaxAge: TimeInterval = 86_400
    /// Resign-active can fire many times an hour; the rolling copy is retaken at most this often.
    public static let rollingMinInterval: TimeInterval = 300

    public struct Entry: Equatable {
        public var name: String
        public var date: Date
        public init(name: String, date: Date) { self.name = name; self.date = date }
    }

    public enum LastBackup: Equatable {
        case never
        case recent(secondsAgo: TimeInterval)
        case stale(daysAgo: Int)
    }

    /// Names to delete. `entries` are the regular files directly in the folder (folders such as a
    /// pre-migration copy are not passed in). A clock that is behind the newest file (a date
    /// in the future) turns every age rule off; the per-extension daily count rule goes by the
    /// date in the file name and still applies.
    public static func pruneVictims(_ entries: [Entry], now: Date) -> [String] {
        var victims: [String] = []
        let clockBehind = entries.contains { $0.date > now.addingTimeInterval(60) }

        for ext in ["json", "store"] {
            let daily = entries.map(\.name).filter { isDaily($0) && $0.hasSuffix("." + ext) }.sorted(by: >)
            if daily.count > dailyKeep { victims += daily.dropFirst(dailyKeep) }
        }
        guard !clockBehind else { return victims }

        for prefix in safetyPrefixes {
            let mine = entries.filter { $0.name.hasPrefix(prefix) && ($0.name.hasSuffix(".json") || $0.name.hasSuffix(".store")) }
                .sorted { $0.date > $1.date }
            for e in mine.dropFirst(safetyKeepNewest) where now.timeIntervalSince(e.date) > safetyMaxAge {
                victims.append(e.name)
            }
        }
        for e in entries where e.name.hasSuffix(".partial") && now.timeIntervalSince(e.date) > partialMaxAge {
            victims.append(e.name)
        }
        return victims
    }

    /// `kronos-2026-10-02.json` / `.store`; not the rolling copy.
    public static func isDaily(_ name: String) -> Bool {
        name.range(of: #"^kronos-\d{4}-\d{2}-\d{2}\.(json|store)$"#, options: .regularExpression) != nil
    }

    /// The rolling copy is due when forced (quit), never taken, taken long enough ago, or the
    /// clock is behind the last copy.
    public static func rollingDue(last: Date?, now: Date, force: Bool) -> Bool {
        guard !force, let last else { return true }
        return now < last || now.timeIntervalSince(last) >= rollingMinInterval
    }

    public static func lastBackup(_ last: Date?, now: Date) -> LastBackup {
        guard let last else { return .never }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 0 { return .recent(secondsAgo: 0) }
        if elapsed >= Double(staleAfterDays) * 86_400 { return .stale(daysAgo: Int(elapsed / 86_400)) }
        return .recent(secondsAgo: elapsed)
    }
}
