// The three completion cues, gated on Settings > General > Sounds. Driver-owned seam: screens
// call `KronosSounds.play(.task)` after a completion; they never touch AVFoundation themselves.
import Foundation

@MainActor
enum KronosSounds {
    enum Cue: String { case task, subtask, impuls }

    static var isEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "kronos.sounds.enabled") == nil ? true : d.bool(forKey: "kronos.sounds.enabled")
    }

    static func play(_ cue: Cue) {
        guard isEnabled else { return }
        SoundPreviewPlayer.play(cue.rawValue)   // already silent under KRONOS_SNAPSHOT
    }
}
