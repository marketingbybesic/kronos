// Kronos/Impuls/ImpulsMentor.swift
// The AI seam for the mentor line ONLY. The displayed task is
// decided once, synchronously, by RankingEngine before this type is even asked anything;
// this type may replace exactly one string, exactly once, inside a 4 s budget, and drops
// silently on timeout, error, a lint failure, or the user having already moved on.
//
// No `AIRouting` is injected by any code in this file — the real router is wired into
// ImpulsScreen's initializer elsewhere. `ImpulsFixtureRouting` below exists only so this
// screen's own snapshot/debug path can exercise the crossfade without a network call.

import Foundation
import KronosCore

/// A generic-then-maybe-AI mentor line, owned by one Impuls card's lifetime. Never touches
/// the task selection; `apply` is a no-op once `lock()` has been called (Start/Another/
/// Skip/energy-change/close all call it) so a late response can never land on a dismissed
/// or superseded card.
@MainActor
@Observable
final class ImpulsMentor {
    private(set) var line: String
    private(set) var isAIRefined = false
    private var locked = false
    private var task: Task<Void, Never>?

    init(generic: String) { self.line = generic }

    /// Call once per shown card. `taskID` is the ALREADY-DISPLAYED task; a reply naming a
    /// different id is accepted only as a future "Another" candidate elsewhere (§4.2) —
    /// never here, this method only ever writes `line`.
    func requestRefinement(router: AIRouting?,
                           candidates: [Candidate],
                           shownTaskID: UUID,
                           energy: KEnergyLevel,
                           language: String) {
        guard let router, !locked else { return }
        let generic = line
        task = Task {
            let start = ContinuousClock.now
            do {
                let result = try await router.impulsPick(candidates: candidates, energy: energy, language: language)
                guard let entry = result.ranked.first(where: { entry in
                    // position is a 1-based index into `candidates`; only accept it when it
                    // names the SAME task already on screen (§4.3 — never swap the task).
                    entry.position >= 1 && entry.position <= candidates.count
                        && candidates[entry.position - 1].taskID == shownTaskID
                }) else { return }
                guard MentorLineCheck.pass(entry.mentorLine, unlessIdenticalTo: generic) else { return }
                try Task.checkCancellation()
                // Floor: never change the line while the user's eyes are still landing on it.
                let elapsed = start.duration(to: .now)
                let floor: Duration = .milliseconds(600)
                if elapsed < floor { try? await Task.sleep(for: floor - elapsed) }
                guard !self.locked else { return }
                self.line = entry.mentorLine
                self.isAIRefined = true
            } catch {
                return   // silent drop — no spinner was ever shown, so nothing to clear
            }
        }
        // Hard 4 s abandonment, independent of the router's own timeout: cancels the
        // continuation and leaves the generic line exactly as it was (§4.2).
        Task {
            try? await Task.sleep(for: .seconds(ImpulsConfig.aiBudgetSeconds))
            task?.cancel()
        }
    }

    /// Freezes the line. Called by every exit path (Start, Another, Skip, energy change,
    /// close) so an in-flight response can never mutate a card the user has already acted on.
    func lock() { locked = true; task?.cancel() }
}

enum ImpulsConfig {
    /// Measured `auto/cheap` median is 3.98 s: a 2.5–3 s budget would discard the median
    /// successful response. Re-measure if the provider changes.
    static let aiBudgetSeconds: Double = 4
}

/// UI-side mirror of Core's `MentorLineLint` rule. Core does not ship this type (only
/// `ImpulsRanking.Entry`'s doc comment states the shape), so this checks the rules it can
/// verify cheaply before ever letting a line replace the generic one. A line that fails is
/// dropped exactly like a timeout — no retry, no error.
enum MentorLineCheck {
    private static let bannedSubstrings: [String] = [
        "you've got this", "you can do it", "come on", "let's go", "crush it", "smash it",
        "just do it", "you did", "you should", "as promised", "one more push", "let's finally",
        "before it's too late", "while you still can", "quick!", "now or never",
        "still not done", "don't forget", "you've been avoiding",
    ]

    static func pass(_ line: String, unlessIdenticalTo generic: String) -> Bool {
        guard line != generic else { return false }
        guard line.count <= 90 else { return false }
        guard !line.contains("!"), !line.contains("?") else { return false }
        let dotCount = line.filter { $0 == "." }.count
        guard dotCount <= 1 else { return false }
        guard !line.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.properties.isEmojiPresentation }) else { return false }
        let lower = line.lowercased()
        return !bannedSubstrings.contains { lower.contains($0) }
    }
}
