// Kronos/Settings/SoundPreviewPlayer.swift
// Plays a cue file for completions and for the Preview button next to each sound row: a custom
// file (CustomSoundPrefs, "Use my own sound…") if one was set for the cue, else the bundled
// Kronos/Resources/Sounds/*.caf. Every file has a small pool of preloaded players, so two
// completions in quick succession both sound instead of the second cutting the first.
// Never touches audio under KRONOS_SNAPSHOT.

import AVFoundation
import Foundation

@MainActor
enum SoundPreviewPlayer {
    private static var pools: [String: SoundPlayerPool] = [:]

    /// Preview entry point: `name` is a cue name ("task", "subtask", "impuls"); a task preview
    /// plays one of the variants like a real completion does.
    static func play(_ name: String) {
        if let cue = KronosSounds.Cue(rawValue: name) { KronosSounds.playAlways(cue) } else { play(cue: name, file: name) }
    }

    static func play(cue: String, file: String) {
        guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil else { return }
        guard let url = CustomSoundPrefs.customURL(for: cue) ?? bundled(file) else { return }
        pool(for: url).playNext()
    }

    static func preload(file: String) {
        guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil, let url = bundled(file) else { return }
        _ = pool(for: url)
    }

    private static func bundled(_ file: String) -> URL? {
        Bundle.main.url(forResource: file, withExtension: "caf", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: file, withExtension: "caf")
    }

    /// Keyed by path and modification date, so replacing a custom file picks up the new bytes.
    private static func pool(for url: URL) -> SoundPlayerPool {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = url.path + "|" + String(mod?.timeIntervalSince1970 ?? 0)
        if let p = pools[key] { return p }
        let p = SoundPlayerPool(url: url, size: 3)
        pools[key] = p
        return p
    }
}

// PLAYER-POOL-BEGIN
/// Which pool slot plays next: the first idle one; when all are busy, the one furthest along
/// (its restart cuts the least audible sound).
enum SoundPoolSlot {
    static func choose(playing: [Bool], progress: [TimeInterval]) -> Int {
        if let idle = playing.firstIndex(of: false) { return idle }
        var best = 0
        for i in progress.indices where progress[i] > progress[best] { best = i }
        return best
    }
}

/// `size` AVAudioPlayers for one file, loaded and prepared up front.
@MainActor
final class SoundPlayerPool {
    private let players: [AVAudioPlayer]

    init(url: URL, size: Int, volume: Float = 1) {
        players = (0..<size).compactMap { _ in
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
            p.volume = volume
            p.prepareToPlay()
            return p
        }
    }

    var count: Int { players.count }

    @discardableResult
    func playNext() -> Int? {
        guard !players.isEmpty else { return nil }
        let i = SoundPoolSlot.choose(playing: players.map(\.isPlaying), progress: players.map(\.currentTime))
        players[i].currentTime = 0
        players[i].play()
        return i
    }

    var playingCount: Int { players.filter(\.isPlaying).count }
}
// PLAYER-POOL-END
