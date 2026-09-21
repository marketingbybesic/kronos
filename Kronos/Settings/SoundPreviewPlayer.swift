// Kronos/Settings/SoundPreviewPlayer.swift
// Plays one of the three cues for the Preview button next to each sound row: a custom file
// (CustomSoundPrefs, "Use my own sound…") if one was set for this cue, else the bundled
// Kronos/Resources/Sounds/*.caf — same fallback order `KronosSounds.play` needs at the real
// completion call sites (see that file's header for the exact lookup lines). Never touches
// audio under KRONOS_SNAPSHOT.

import AVFoundation
import Foundation

@MainActor
enum SoundPreviewPlayer {
    private static var player: AVAudioPlayer?

    static func play(_ name: String) {
        guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil else { return }
        guard let url = CustomSoundPrefs.customURL(for: name)
            ?? Bundle.main.url(forResource: name, withExtension: "caf", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "caf") else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
