// The completion cues, gated on Settings > General > Sounds. Driver-owned seam: screens call
// `KronosSounds.play(.task)` after a completion; they never touch AVFoundation themselves.
//
// - `.task` has four pitch variants (task, task2, task3, task4); one is picked at random and
//   never the same as the one before, so the reward does not habituate.
// - `.parent` is the three-note cue for finishing a parent whose children are all done.
// - `.dayclear` is the long cue for an empty Today.
// - A custom file chosen in Settings (CustomSoundPrefs) replaces every variant of its cue.
import Foundation

@MainActor
enum KronosSounds {
    enum Cue: String, CaseIterable {
        case task, subtask, impuls, parent, dayclear

        /// Bundled file names (without extension) this cue picks from.
        var files: [String] {
            switch self {
            case .task: return ["task", "task2", "task3", "task4"]
            case .parent: return ["parent"]
            case .dayclear: return ["dayclear"]
            case .subtask: return ["subtask"]
            case .impuls: return ["impuls"]
            }
        }
    }

    static var isEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "kronos.sounds.enabled") == nil ? true : d.bool(forKey: "kronos.sounds.enabled")
    }

    private static var lastVariant: [Cue: Int] = [:]
    private static var generator = SystemRandomNumberGenerator()

    static func play(_ cue: Cue) {
        guard isEnabled else { return }
        playAlways(cue)
    }

    /// Plays regardless of the Sounds switch (the Preview buttons in Settings).
    static func playAlways(_ cue: Cue) {
        SoundPreviewPlayer.play(cue: cue.rawValue, file: pickFile(cue))   // silent under KRONOS_SNAPSHOT
    }

    /// Loads every bundled cue into its player pool so the first completion does not wait on disk.
    static func preload() {
        for cue in Cue.allCases { for f in cue.files { SoundPreviewPlayer.preload(file: f) } }
    }

    static func pickFile(_ cue: Cue) -> String {
        let files = cue.files
        let i = SoundVariantPicker.next(count: files.count, last: lastVariant[cue], using: &generator)
        lastVariant[cue] = i
        return files[i]
    }
}

// VARIANT-PICKER-BEGIN
/// Chooses which variant plays next: uniform over every index except the one played last.
enum SoundVariantPicker {
    static func next<G: RandomNumberGenerator>(count: Int, last: Int?, using g: inout G) -> Int {
        guard count > 1 else { return 0 }
        guard let last, (0..<count).contains(last) else { return Int(g.next() % UInt64(count)) }
        let r = Int(g.next() % UInt64(count - 1))
        return r >= last ? r + 1 : r
    }
}
// VARIANT-PICKER-END
