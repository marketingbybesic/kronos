// Kronos/Welcome/OnboardingQuests.swift — "Start here": learn by doing, not by reading.
// The old first run was a 7-page text tour with Skip next to Next; ADHD readers skipped it. Now
// the user DOES five small things in the real app and each quest ticks itself the moment the
// store shows it happened: no "mark as done", no reading first. Only ONE next quest is shown
// at a time. The basics cannot be dismissed (only collapsed); the five power quests after them
// can. Foundation only: scripts/onboarding-selftest.swift compiles this file standalone.
import Foundation

enum Quest: String, CaseIterable, Codable, Sendable {
    // Basics — the core loop: in, smaller, context, next, done.
    case capture, firstStep, attach, seeNext, finish
    // Power — one surface each, ticked when it is opened once.
    case triage, impuls, captureNotes, timeBlocks, palette

    static let basics: [Quest] = [.capture, .firstStep, .attach, .seeNext, .finish]
    static let power: [Quest] = [.triage, .impuls, .captureNotes, .timeBlocks, .palette]
    var isBasic: Bool { Self.basics.contains(self) }
}

/// What happened since the tour started, as plain counts the app measures from the store and
/// from a few "surface opened" signals. Never written by the UI directly.
struct OnboardingFacts: Equatable, Sendable {
    var tasksCreated = 0
    var subtasksCreated = 0
    /// Attachments now minus attachments when the tour started (never negative in practice).
    var attachmentsAdded = 0
    /// The menu-bar "what's next" popover was opened.
    var nextShown = false
    /// Tasks or subtasks completed.
    var completed = 0
    /// Power surfaces opened (triage, impuls, captureNotes, timeBlocks, palette).
    var opened: Set<Quest> = []
}

/// Persisted in UserDefaults as JSON.
struct OnboardingState: Codable, Equatable, Sendable {
    var startedAt: Date?
    var done: [Quest] = []
    var collapsed = false
    var powerDismissed = false
    var baselineAttachments = 0
    var permissionsOffered = false
}

enum OnboardingPhase: Equatable, Sendable {
    case notStarted
    case basics(done: Int)
    case power(done: Int)
    case finished
}

enum OnboardingLogic {
    /// Quests the facts prove, that are not yet done, in canonical order.
    static func newlyDone(_ facts: OnboardingFacts, done: [Quest]) -> [Quest] {
        Quest.allCases.filter { !done.contains($0) && isMet($0, facts) }
    }

    static func isMet(_ quest: Quest, _ f: OnboardingFacts) -> Bool {
        switch quest {
        case .capture: f.tasksCreated > 0
        case .firstStep: f.subtasksCreated > 0
        case .attach: f.attachmentsAdded > 0
        case .seeNext: f.nextShown
        case .finish: f.completed > 0
        case .triage, .impuls, .captureNotes, .timeBlocks, .palette: f.opened.contains(quest)
        }
    }

    static func phase(_ s: OnboardingState) -> OnboardingPhase {
        guard s.startedAt != nil else { return .notStarted }
        let basicsDone = Quest.basics.filter(s.done.contains).count
        if basicsDone < Quest.basics.count { return .basics(done: basicsDone) }
        let powerDone = Quest.power.filter(s.done.contains).count
        if s.powerDismissed || powerDone == Quest.power.count { return .finished }
        return .power(done: powerDone)
    }

    /// The ONE quest the card puts forward: the first undone basic, then the first undone power
    /// quest; nil when not started or finished.
    static func next(_ s: OnboardingState) -> Quest? {
        switch phase(s) {
        case .notStarted, .finished: nil
        case .basics: Quest.basics.first { !s.done.contains($0) }
        case .power: Quest.power.first { !s.done.contains($0) }
        }
    }

    /// Only the optional power level may be dismissed; the basics can merely be collapsed.
    static func canDismiss(_ s: OnboardingState) -> Bool {
        if case .power = phase(s) { return true }
        return false
    }

    /// The permission window waits until the basics are done — it used to open on top of the
    /// very first step, the worst moment to ask anything.
    static func shouldOfferPermissions(_ s: OnboardingState, permissionsAlreadyShown: Bool) -> Bool {
        guard !permissionsAlreadyShown, !s.permissionsOffered else { return false }
        switch phase(s) {
        case .power, .finished: return true
        case .notStarted, .basics: return false
        }
    }
}
