// Kronos/Triage/TriageMode.swift
//
// The card flow serves two sittings: sorting tasks that miss data, and Sweep, the short review
// of what has gone quiet. Whoever opens the flow (the sidebar row, the palette) says which one
// before it appears; the card reads and clears the request when it shows.
import SwiftUI
import Observation

enum TriageMode: Equatable {
    case sort, sweep, review
}

@MainActor
@Observable
final class TriageLaunch {
    static let shared = TriageLaunch()
    private init() {}

    /// The mode the next appearance will show; a plain open leaves it at `.sort`.
    private(set) var requested: TriageMode = .sort
    /// Bumps on every request so a card that is already on screen can switch mode in place.
    private(set) var token = 0

    func request(_ mode: TriageMode) {
        requested = mode
        token += 1
    }

    /// Reads the pending request and resets it, so it applies to exactly one appearance.
    func consume() -> TriageMode {
        defer { requested = .sort }
        return requested
    }
}
