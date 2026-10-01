// Kronos/Welcome/OnboardingCenter.swift — live side of "Start here" (OnboardingQuests.swift holds
// the pure rules). Measures what the user really did since the tour started — straight from the
// store (tasks/subtasks created after `startedAt`, attachments beyond the starting count,
// completions) plus two kinds of "a surface opened" signals — and ticks quests with a sound.
// "Show me" opens the exact surface a quest is about, so starting a quest costs one click.
import SwiftUI
import AppKit
import KronosCore

extension Notification.Name {
    /// Posted by MenuBarOrdoController when its "what's next" popover appears.
    static let kronosOrdoPopoverShown = Notification.Name("kronosOrdoPopoverShown")
}

@Observable
@MainActor
final class OnboardingCenter {
    static let shared = OnboardingCenter()

    private(set) var state = OnboardingState()
    /// The quest that ticked last, for a moment of visible reward on the card.
    private(set) var justDone: Quest?
    /// Set by AppDelegate: shows the permissions window once the basics are done.
    var offerPermissions: (() -> Void)?

    private static let defaultsKey = "kronos.onboarding.v1"
    private var nextShown = false
    private var opened: Set<Quest> = []
    private weak var model: AppModel?

    /// Snapshot / UI-test / self-test runs share the app's defaults domain: never read the
    /// a user's tour state there (same three guards as WelcomeGate).
    private static var isHermetic: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["KRONOS_SNAPSHOT"] != nil || env["KRONOS_STORE_DIR"] != nil || env["KRONOS_SELFTEST"] != nil
    }

    private init() {
        if !Self.isHermetic, let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(OnboardingState.self, from: data) {
            state = saved
        }
        NotificationCenter.default.addObserver(forName: .kronosOrdoPopoverShown, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let center = OnboardingCenter.shared
                center.nextShown = true
                if let model = center.model { center.refresh(model) }
            }
        }
    }

    var phase: OnboardingPhase { OnboardingLogic.phase(state) }
    var next: Quest? { OnboardingLogic.next(state) }
    var isVisible: Bool { phase != .notStarted && phase != .finished }

    // MARK: Lifecycle

    func start(model: AppModel) {
        self.model = model
        guard state.startedAt == nil else { return }
        state.startedAt = Date()
        state.baselineAttachments = Self.attachmentCount(model.store)
        save()
    }

    /// Help > Start here: brings the card back, also after it was finished or dismissed.
    func reopen(model: AppModel) {
        self.model = model
        if state.startedAt == nil { start(model: model) }
        state.powerDismissed = false
        state.collapsed = false
        if phase == .finished {  // everything ticked: start over so the card has something to teach
            state = OnboardingState(startedAt: Date(), baselineAttachments: Self.attachmentCount(model.store),
                                    permissionsOffered: true)
            nextShown = false
            opened = []
        }
        save()
    }

    func setCollapsed(_ collapsed: Bool) { state.collapsed = collapsed; save() }

    /// The circle on a quest row: the user says "done" (did it another way, or knows it).
    func markDone(_ quest: Quest) {
        guard state.startedAt != nil, !state.done.contains(quest) else { return }
        state.done.append(quest)
        justDone = quest
        KronosSounds.play(.subtask)
        save()
    }

    func dismissPower() {
        guard OnboardingLogic.canDismiss(state) else { return }
        state.powerDismissed = true
        save()
    }

    // MARK: Measuring

    /// Surfaces the APP opened on its own (the morning plan opening Impuls): the next
    /// `noteOpened` for each is swallowed, because opening it did not teach the user anything.
    private var programmaticOpens: Set<Quest> = []
    func markProgrammaticOpen(_ quest: Quest) { programmaticOpens.insert(quest) }

    /// Ticks the "open this surface" quest only when `byUser`: the user opened it deliberately
    /// (shortcut, palette, menu, "Show me"), not the morning card or any other code path.
    func noteOpened(_ quest: Quest, model: AppModel, byUser: Bool = true) {
        let swallowed = programmaticOpens.remove(quest) != nil
        guard byUser, !swallowed else { return }
        opened.insert(quest)
        refresh(model)
    }

    /// Re-measures and ticks whatever the facts now prove. Cheap: one pass over the live tasks.
    func refresh(_ model: AppModel) {
        self.model = model
        // Snapshot/UI-test runs import their seed AFTER a fixture's start time: never measure there.
        guard !Self.isHermetic, let since = state.startedAt, phase != .finished else { return }
        let before = phase
        let ticked = OnboardingLogic.newlyDone(facts(model.store, since: since), done: state.done)
        guard !ticked.isEmpty else { return }
        state.done += ticked
        justDone = ticked.last
        let basicsJustFinished: Bool = {
            if case .basics = before, case .basics = phase { return false }
            if case .basics = before { return true }
            return false
        }()
        KronosSounds.play(basicsJustFinished ? .task : .subtask)
        save()
        let shown = ticked.last
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.justDone == shown { self?.justDone = nil }
        }
        let permissionsShown = UserDefaults.standard.bool(forKey: "kronos.permissions.shownOnce")
        if OnboardingLogic.shouldOfferPermissions(state, permissionsAlreadyShown: permissionsShown) {
            state.permissionsOffered = true
            save()
            offerPermissions?()
        }
    }

    private func facts(_ store: TaskStore, since: Date) -> OnboardingFacts {
        let tasks = store.allTasks()
        let subtasks = tasks.flatMap { $0.subtasks ?? [] }
        var f = OnboardingFacts()
        f.tasksCreated = tasks.filter { $0.createdAt > since }.count
        f.subtasksCreated = subtasks.filter { $0.createdAt > since }.count
        f.attachmentsAdded = Self.attachmentCount(store) - state.baselineAttachments
        f.nextShown = nextShown
        f.completed = tasks.filter { ($0.completedAt ?? .distantPast) > since }.count
            + subtasks.filter { $0.isDone && $0.updatedAt > since }.count
        f.opened = opened
        return f
    }

    private static func attachmentCount(_ store: TaskStore) -> Int {
        store.allTasks().reduce(0) { sum, t in
            sum + ContextLink.findAll(in: t.notes).count
                + (t.subtasks ?? []).reduce(0) { $0 + ContextLink.findAll(in: $1.notes).count }
        }
    }

    // MARK: Show me

    /// One click from reading a quest to doing it.
    func showMe(_ quest: Quest, model: AppModel) {
        self.model = model
        switch quest {
        case .capture:
            NotificationCenter.default.post(name: .kronosQuickAddPanelRequested, object: nil)
        case .firstStep, .attach, .finish:
            // Put a task in front of the user: the newest one they made, else the one in focus.
            let since = state.startedAt ?? .distantPast
            let newest = model.store.allTasks().filter { $0.createdAt > since && $0.status != .done }
                .max { $0.createdAt < $1.createdAt }
            guard let id = newest?.id ?? model.focusTaskID ?? model.store.allTasks().first(where: { $0.status != .done })?.id else {
                // Nothing to act on yet: the first thing to learn is getting a task in.
                NotificationCenter.default.post(name: .kronosQuickAddPanelRequested, object: nil)
                return
            }
            // The list drops a selection it does not contain (a new task sits in Inbox while the
            // user may be on Today): show All, where it is, then select it so the inspector opens.
            if model.scope != .all { model.scope = .all; model.persist() }
            model.selectedTaskID = id
            NSApp.activate(ignoringOtherApps: true)
            if quest == .firstStep {
                // The inspector mounts on selection; focus its Add subtask field once it is there.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .kronosFocusAddSubtaskRequested, object: nil)
                }
            }
            if quest == .attach {
                // Something to drag from: a Finder window next to Kronos.
                let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
                NSWorkspace.shared.open(downloads)
            }
        case .seeNext:
            NotificationCenter.default.post(name: .kronosShowOrdoRequested, object: nil)
        case .triage: model.isTriageOpen = true
        case .impuls: model.isImpulsOpen = true
        case .captureNotes: model.isCaptureOpen = true
        case .timeBlocks: model.isTimeBlocksOpen = true
        case .palette: model.isPaletteOpen = true
        }
    }

    private func save() {
        guard !Self.isHermetic, let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Snapshot fixtures only: a fixed state, never persisted.
    func setFixture(_ fixture: OnboardingState, justDone: Quest? = nil) {
        state = fixture
        self.justDone = justDone
    }
}
