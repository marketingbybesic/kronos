// Kronos/Welcome/OnboardingQuests.swift — "Learn Kronos": learn by doing, not by reading.
// The old first run was a 7-page text tour with Skip next to Next; ADHD readers skipped it. Now
// the user DOES three small things in the real app (write something down, break it into a first
// step, finish a step) and each quest ticks itself the moment the store shows it happened: no
// "mark as done", no reading first. Only ONE next quest is shown at a time. Everything after the
// three basics is optional, and "Enough for now" is available at every point: nobody is held
// hostage by a checklist. Foundation only: scripts/onboarding-selftest.swift compiles this file
// standalone.
import Foundation

enum Quest: String, CaseIterable, Codable, Sendable {
    // Basics: the core loop. In, smaller, done.
    case capture, firstStep, finish
    // More: one surface or one habit each, ticked when it happens (or is opened once).
    case triage, impuls, seeNext, attach, captureNotes, timeBlocks, palette

    static let basics: [Quest] = [.capture, .firstStep, .finish]
    static let power: [Quest] = [.triage, .impuls, .seeNext, .attach, .captureNotes, .timeBlocks, .palette]
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
    /// Surfaces opened (triage, impuls, captureNotes, timeBlocks, palette).
    var opened: Set<Quest> = []
}

/// Persisted in the app's defaults (`KronosEnv.defaults`) as JSON.
struct OnboardingState: Codable, Equatable, Sendable {
    var startedAt: Date?
    var done: [Quest] = []
    var collapsed = false
    /// "Enough for now": the card is gone until Help brings it back. Older builds could only
    /// set this after the basics and stored it as `powerDismissed`; both spellings decode.
    var dismissed = false
    var baselineAttachments = 0
    var permissionsOffered = false
    /// The one-time "next time, press the shortcut from any app" line, open after the first
    /// capture until the user closes it or finishes another quest.
    var captureHintOpen = false

    init(startedAt: Date? = nil, done: [Quest] = [], collapsed: Bool = false, dismissed: Bool = false,
         baselineAttachments: Int = 0, permissionsOffered: Bool = false, captureHintOpen: Bool = false) {
        self.startedAt = startedAt
        self.done = done
        self.collapsed = collapsed
        self.dismissed = dismissed
        self.baselineAttachments = baselineAttachments
        self.permissionsOffered = permissionsOffered
        self.captureHintOpen = captureHintOpen
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, done, collapsed, dismissed, powerDismissed, baselineAttachments, permissionsOffered, captureHintOpen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        // A quest that no longer exists in this build (older saves) is dropped, not fatal.
        let raw = try c.decodeIfPresent([String].self, forKey: .done) ?? []
        done = raw.compactMap(Quest.init(rawValue:))
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed)
            ?? c.decodeIfPresent(Bool.self, forKey: .powerDismissed) ?? false
        baselineAttachments = try c.decodeIfPresent(Int.self, forKey: .baselineAttachments) ?? 0
        permissionsOffered = try c.decodeIfPresent(Bool.self, forKey: .permissionsOffered) ?? false
        captureHintOpen = try c.decodeIfPresent(Bool.self, forKey: .captureHintOpen) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encode(done.map(\.rawValue), forKey: .done)
        try c.encode(collapsed, forKey: .collapsed)
        try c.encode(dismissed, forKey: .dismissed)
        try c.encode(baselineAttachments, forKey: .baselineAttachments)
        try c.encode(permissionsOffered, forKey: .permissionsOffered)
        try c.encode(captureHintOpen, forKey: .captureHintOpen)
    }
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
        if s.dismissed { return .finished }
        let basicsDone = Quest.basics.filter(s.done.contains).count
        if basicsDone < Quest.basics.count { return .basics(done: basicsDone) }
        let powerDone = Quest.power.filter(s.done.contains).count
        if powerDone == Quest.power.count { return .finished }
        return .power(done: powerDone)
    }

    /// The ONE quest the card puts forward: the first undone basic, then the first undone
    /// quest after them; nil when not started, dismissed or finished.
    static func next(_ s: OnboardingState) -> Quest? {
        switch phase(s) {
        case .notStarted, .finished: nil
        case .basics: Quest.basics.first { !s.done.contains($0) }
        case .power: Quest.power.first { !s.done.contains($0) }
        }
    }

    /// "Enough for now" is there whenever the card is: in the basics and after them.
    static func canDismiss(_ s: OnboardingState) -> Bool {
        switch phase(s) {
        case .basics, .power: true
        case .notStarted, .finished: false
        }
    }

    /// The permission explainer waits until the basics are done: it used to open on top of the
    /// very first step, the worst moment to ask anything. Someone who said "enough" is never
    /// asked unprompted.
    static func shouldOfferPermissions(_ s: OnboardingState, permissionsAlreadyShown: Bool) -> Bool {
        guard !permissionsAlreadyShown, !s.permissionsOffered, !s.dismissed else { return false }
        switch phase(s) {
        case .power, .finished: return true
        case .notStarted, .basics: return false
        }
    }

    /// The shortcut line opens when the first capture ticks and never again; it closes when
    /// the user moves on to any other quest.
    static func captureHintOpens(ticked: [Quest], state: OnboardingState) -> Bool {
        ticked.contains(.capture) && !state.done.contains(.capture) && !state.dismissed
    }

    static func captureHintCloses(ticked: [Quest]) -> Bool {
        ticked.contains { $0 != .capture }
    }

    /// The tour makes a sample task only where the tour would otherwise point at nothing: no
    /// open task exists. It never touches a store that already has work in it.
    static func sampleTaskNeeded(openTaskCount: Int) -> Bool { openTaskCount == 0 }

    /// Facts exclude the tour's own sample tasks and their steps: making and finishing a sample
    /// must never tick "write down one thing".
    static func isSampleRow(id: UUID, parentID: UUID?, sampleIDs: Set<UUID>) -> Bool {
        sampleIDs.contains(id) || (parentID.map(sampleIDs.contains) ?? false)
    }

    /// "1.2 (34)" from the bundle's Info.plist values, "1.2" when the build number is the same or
    /// missing; nil when there is no bundle version at all (the snapshot harness, tools).
    static func versionLabel(short: String?, build: String?) -> String? {
        guard let short, !short.isEmpty else { return nil }
        guard let build, !build.isEmpty, build != short else { return short }
        return "\(short) (\(build))"
    }
}
