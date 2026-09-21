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
    /// full disk mid-write never leaves a half-written backup on disk.
    public static func write(_ envelope: KronosExportEnvelope, to url: URL) throws {
        let data = try KronosExportCodec.makeEncoder().encode(envelope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
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
