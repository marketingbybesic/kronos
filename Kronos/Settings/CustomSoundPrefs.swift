// Kronos/Settings/CustomSoundPrefs.swift
// Per-cue "Use my own sound…": the built-in cues are the default, and a custom file per cue
// is the escape hatch for whatever cue actually works for a given user. The chosen file is
// COPIED into Application Support (KronosStore.containerDirectory(), the same hermetic-aware
// home the real store/backups use) so it survives the source file moving or being deleted,
// then its path is stored here. Falling back to the built-in bundled cue if the custom file
// goes missing is `KronosSounds`'s job — see the file-header comment there for the exact
// lookup lines it needs.
import Foundation
import KronosCore

enum CustomSoundPrefs {
    private static func key(_ cue: String) -> String { "kronos.sounds.custom.\(cue)" }

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .snapshotScratchSounds : .standard
    }

    /// The custom file for `cue` ("task"/"subtask"/"impuls"), or nil to use the built-in cue.
    /// Returns nil (falls back silently) if the stored path no longer exists on disk — a
    /// moved/deleted custom file must never throw or play silence, it just reverts to
    /// default, same as any "custom X, else built-in" setting elsewhere in the app.
    static func customURL(for cue: String) -> URL? {
        guard let path = defaults.string(forKey: key(cue)) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies `sourceURL` into `<Application Support>/Kronos/Sounds/<cue>.<ext>`, replacing
    /// any earlier custom file for this cue, and stores the copy's path. Returns the copy's
    /// URL on success; nil if the copy failed (caller shows nothing changed, keeps playing
    /// the previous choice — never a half-written custom sound).
    @discardableResult
    static func setCustom(_ sourceURL: URL, for cue: String) -> URL? {
        let dir = KronosStoreSoundsDirectory.url()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let dest = dir.appendingPathComponent("\(cue).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            return nil
        }
        defaults.set(dest.path, forKey: key(cue))
        return dest
    }

    /// Reverts `cue` to the built-in bundled sound.
    static func clearCustom(for cue: String) {
        defaults.removeObject(forKey: key(cue))
    }
}

/// Kept separate from `KronosStore.containerDirectory()` (KronosCore) only because this file
/// needs its own hermetic `Sounds/` subfolder name in one place; the parent directory itself
/// already resolves `KRONOS_STORE_DIR`/the real Application Support path for us.
private enum KronosStoreSoundsDirectory {
    static func url() -> URL {
        KronosStore.containerDirectory().appendingPathComponent("Sounds", isDirectory: true)
    }
}

private extension UserDefaults {
    static let snapshotScratchSounds = UserDefaults(suiteName: "kronos.snapshot.sounds." + UUID().uuidString) ?? .standard
}
