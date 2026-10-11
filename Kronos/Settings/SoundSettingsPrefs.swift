// Kronos/Settings/SoundSettingsPrefs.swift
// Per-cue on/off, output volume, and the completion-animation switch — the internal notes
// §8.3. Same persistence shape as CustomSoundPrefs (per-cue key fn + snapshot-aware `defaults`),
// kept in its own file because it is a different axis (whether/how loud a cue plays, not which
// file it plays).
//
// Master-vs-per-cue interaction (judgment call, the internal notes:691 is explicit so this is
// not actually ambiguous, just stating it here): "Sounds" (SettingsGeneralTab's `soundsEnabled`,
// `kronos.sounds.enabled`, read by `KronosSounds.isEnabled`) stays the overall kill switch —
// "Off = all three silent" — and each per-cue switch here is independent ON TOP of it, so a cue
// only actually plays when BOTH the master and its own switch are on. Turning the master back on
// restores whatever each cue's own switch was last set to, never forces all three back on.
import Foundation
import SwiftUI

enum SoundSettingsPrefs {
    private static func enabledKey(_ cue: String) -> String { "kronos.sounds.enabled.\(cue)" }
    private static let volumeKey = "kronos.sounds.volume"
    private static let completionAnimationKey = "kronos.sounds.completionAnimation"

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .snapshotScratchSoundSettings : .standard
    }

    /// Per-cue switch ("task"/"subtask"/"impuls"), independent of the other two cues — on by
    /// default, ANDed with the master `kronos.sounds.enabled` toggle by callers (`KronosSounds.play`).
    static func isCueEnabled(_ cue: String) -> Bool {
        defaults.object(forKey: enabledKey(cue)) == nil ? true : defaults.bool(forKey: enabledKey(cue))
    }

    static func setCueEnabled(_ on: Bool, for cue: String) {
        defaults.set(on, forKey: enabledKey(cue))
    }

    /// 0...1, default 0.7 ("Volume — 0-100%, default 70%, applied to all three.").
    static var volume: Float {
        get { defaults.object(forKey: volumeKey) == nil ? 0.7 : defaults.float(forKey: volumeKey) }
        set { defaults.set(newValue, forKey: volumeKey) }
    }

    /// On by default. The Settings row forces this off (and the stored value untouched) while
    /// `Motion.reduceMotion` is true — this pref is only ever read/written while that is false.
    /// The value is MIRRORED into `Motion.completionAnimationEnabled` (the design-system copy
    /// every completion-transition call site actually reads, so DS never imports Settings):
    /// the setter writes it through, and `AppDelegate` seeds it once at launch.
    @MainActor
    static var completionAnimationEnabled: Bool {
        get {
            defaults.object(forKey: completionAnimationKey) == nil
                ? true : defaults.bool(forKey: completionAnimationKey)
        }
        set {
            defaults.set(newValue, forKey: completionAnimationKey)
            Motion.completionAnimationEnabled = newValue
        }
    }

    /// Forwarded so Settings-side callers keep one name; the real flag lives in `Motion`
    /// (pref AND NOT Reduce Motion, Reduce Motion always wins).
    @MainActor
    static var completionAnimationActive: Bool { Motion.completionAnimationActive }
}

private extension UserDefaults {
    static let snapshotScratchSoundSettings =
        UserDefaults(suiteName: "kronos.snapshot.soundsettings." + UUID().uuidString) ?? .standard
}
