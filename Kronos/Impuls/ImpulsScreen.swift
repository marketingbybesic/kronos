// Kronos/Impuls/ImpulsScreen.swift
//
// ONE calm question — how much energy right now — answered with ONE task's first move.
// Rendered synchronously from RankingEngine (<=100ms); the AI, if wired, may only crossfade
// the mentor line within a 4s budget and can never change the task on screen
// (ImpulsMentor.swift owns that seam). No red, no timers, no streaks, no "!" anywhere.

import SwiftUI
import KronosCore

struct ImpulsScreen: View {
    enum Mode { case ask, morning }

    let model: AppModel
    var mode: Mode = .ask
    /// Injected once a real router exists; nil (the default everywhere in this file) means
    /// Impuls runs fully offline — every line the user sees is generic.
    var aiRouter: AIRouting? = nil
    var engine: RankingProviding = RankingEngine()

    init(model: AppModel, mode: Mode = .ask, aiRouter: AIRouting? = nil, engine: RankingProviding = RankingEngine()) {
        self.model = model
        self.mode = mode
        self.aiRouter = aiRouter
        self.engine = engine
    }

    @State private var energy: KEnergyLevel = .mid
    @State private var excludedIDs: Set<UUID> = []
    @State private var anotherCount = 0
    @State private var current: ImpulsCard?
    @State private var mentor: ImpulsMentor?
    @State private var morningSlots: [UUID] = []
    @FocusState private var isFocused: Bool

    private var language: Lang { Lang(rawValue: KronosLocale.languageCode) ?? .en }
    private var today: Int { Day.today(calendar: KronosLocale.calendar) }

    var body: some View {
        ZStack {
            Tok.bg
            VStack(spacing: Space.x4) {
                content
                if mode == .morning || current != nil { energyRow }
            }
            .padding(Space.x6)
            .frame(maxWidth: 520)
        }
        // Hugs its content: a full-height black column with empty bands above and below the
        // card read as a broken screen (user report); the shell centres it.
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .focusable(true)
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            // No question before the task: the card shows at once from the last energy chosen
            // today, else a time-of-day default. Energy is a small "change" row under the card.
            energy = Self.defaultEnergy()
            reload()
        }
        // Re-evaluate on every store mutation (project convention: SwiftData models are
        // read via manual fetches, never @Query). This also fixes a real ordering bug: a
        // parent view that seeds sample data in ITS OWN `.onAppear` runs that seed AFTER
        // this screen's `.onAppear` (SwiftUI fires a child's `.onAppear` before its
        // parent's), so without this the very first render would be built from whatever
        // was in the store before the seed landed.
        .onChange(of: model.version) { _, _ in reload() }
        .onKeyPress("1") { setEnergy(.low); return .handled }
        .onKeyPress("2") { setEnergy(.mid); return .handled }
        .onKeyPress("3") { setEnergy(.high); return .handled }
        .onKeyPress(.return) { start(); return .handled }
        .onKeyPress(.rightArrow) { another(); return .handled }
        .onKeyPress("a") { another(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    // MARK: Energy question

    /// Hour 12 under the snapshot harness so shots do not depend on the clock.
    static func defaultEnergy() -> KEnergyLevel {
        let hermetic = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
        let hour = hermetic ? 12 : KronosLocale.calendar.component(.hour, from: Date())
        let remembered = ImpulsEnergyMemory.todayEnergy().flatMap { ImpulsDefaults.Energy(rawValue: $0.rawValue) }
        return KEnergyLevel(rawValue: ImpulsDefaults.energy(remembered: remembered, hour: hour).rawValue) ?? .mid
    }

    /// Remembered on every change (not only on Start) so a change survives the next open.
    private func setEnergy(_ level: KEnergyLevel) {
        guard energy != level else { return }
        energy = level
        ImpulsEnergyMemory.rememberToday(level)
        reload()
    }

    private var energyRow: some View {
        HStack(spacing: Space.x2) {
            Text(String(localized: "impuls.energy.prompt"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            Spacer()
            energyButton(.low, title: String(localized: "energy.low"))
            energyButton(.mid, title: String(localized: "energy.mid"))
            energyButton(.high, title: String(localized: "energy.high"))
        }
    }

    private func energyButton(_ level: KEnergyLevel, title: String) -> some View {
        let selected = energy == level
        return Button(title) {
            setEnergy(level)
        }
        .kButton(selected ? .secondary : .ghost, size: .compact)
        .kBorder(selected ? Tok.borderActive : .clear, radius: Radius.control)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Content — the card, the dread card, empty, or the morning three

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .morning:
            MorningCardView(candidates: morningEntries, language: language, energy: energy,
                            onAccept: acceptMorning, onDismiss: close, onSwap: swapMorning)
        case .ask:
            if let current, let mentor {
                ImpulsCardView(card: current, mentor: mentor,
                               canAskAnother: canAskAnother,
                               onStart: start, onAnother: another, onSkip: close)
            } else {
                emptyView
            }
        }
    }

    // "impuls.empty.nothingopen" / "impuls.empty.donecount" are missing from the string
    // catalog, so this reuses the closest existing calm line, "empty.today.body", for both
    // empty branches rather than hard-coding new prose, and renders the done-today count as
    // a plain KBadge number rather than an invented sentence.
    private var emptyView: some View {
        let tasks = model.store.allTasks()
        return Group {
            switch ImpulsQuery.emptyReason(tasks: tasks, today: today) {
            case .noTasksYet:
                KEmptyState(icon: "sparkles", title: String(localized: "empty.today.body"))
            case .nothingOpen(let doneToday):
                VStack(spacing: Space.x2) {
                    KEmptyState(icon: "check-square", title: String(localized: "empty.today.body"))
                    if doneToday > 0 { KBadge("\(doneToday)") }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Ranking + mentor lifecycle

    private var canAskAnother: Bool {
        anotherCount < 3 && !nextCandidatesWouldBeEmpty
    }

    private var nextCandidatesWouldBeEmpty: Bool {
        guard let current else { return true }
        var excl = excludedIDs
        excl.insert(current.task.id)
        return ImpulsQuery.candidates(engine: engine, energy: energy, excluding: excl,
                                       tasks: model.store.allTasks(), today: today, count: 1).isEmpty
    }

    private func reload() {
        mentor?.lock()
        excludedIDs = []
        anotherCount = 0
        morningSlots = []
        loadCurrent()
    }

    private func loadCurrent() {
        let tasks = model.store.allTasks()
        let picks = ImpulsQuery.candidates(engine: engine, energy: energy, excluding: excludedIDs,
                                           tasks: tasks, today: today, count: 5)
        guard let top = picks.first, let task = tasks.first(where: { $0.id == top.taskID }) else {
            current = nil
            mentor = nil
            return
        }
        let generic = ImpulsQuery.genericMentorLine(for: task, candidateReason: top.reason, energy: energy)
        current = ImpulsCard(task: task, mentorLine: generic)
        let m = ImpulsMentor(generic: generic)
        mentor = m
        m.requestRefinement(router: aiRouter, candidates: picks, shownTaskID: task.id,
                            energy: energy, language: language.rawValue)
    }

    /// The full ordered pool the morning plan draws from, respecting the "max 1 deep"
    /// diversity rule with the relax-if-short fallback (spec §7.3).
    private func morningPool() -> [KTask] {
        let tasks = model.store.allTasks()
        let picks = ImpulsQuery.candidates(engine: engine, energy: energy, excluding: [],
                                           tasks: tasks, today: today, count: 12, forceDeep: true)
        let resolved = picks.compactMap { c in tasks.first(where: { $0.id == c.taskID }) }
        var diversified: [KTask] = []
        var deepUsed = false
        for t in resolved {
            if t.depth == .deep {
                if deepUsed { continue }
                deepUsed = true
            }
            diversified.append(t)
        }
        return diversified.count >= 3 ? diversified : resolved
    }

    /// Materializes `morningSlots` into (task, firstMove) pairs, seeding the slots from the
    /// pool on first read so `.onAppear` and swaps share one source of truth.
    private var morningEntries: [(task: KTask, firstMove: String)] {
        let pool = morningPool()
        let ids = morningSlots.isEmpty ? Array(pool.prefix(3)).map(\.id) : morningSlots
        return ids.compactMap { id in
            pool.first(where: { $0.id == id }).map { ($0, ImpulsQuery.firstMove(for: $0, language: language)) }
        }
    }

    private func swapMorning(_ index: Int) {
        let pool = morningPool()
        var ids = morningSlots.isEmpty ? Array(pool.prefix(3)).map(\.id) : morningSlots
        guard index < ids.count else { return }
        if let next = pool.first(where: { !ids.contains($0.id) }) { ids[index] = next.id }
        morningSlots = ids
    }

    // MARK: Actions (spec §4.5)

    private func start() {
        guard let current else { return }
        KronosSounds.play(.impuls)   // the one "go" cue; honours Settings > General > Sounds
        mentor?.lock()
        model.store.setStatus(current.task.id, .inProgress)
        model.selectedTaskID = current.task.id
        // Ledger G8: Start pins the task as focus, so the list's Now card, the sidebar tint
        // and the menu bar all follow it (they all read `model.focusTaskID`, which prefers
        // `pinnedFocusTaskID` over the automatic Ordo pick).
        model.pinnedFocusTaskID = current.task.id
        switch ImpulsDefaults.startScope(projectID: current.task.projectID) {
        case .project(let id): model.scope = .project(id)
        case .all: model.scope = .all
        }
        model.didMutate()
        ImpulsEnergyMemory.rememberToday(energy)
        close()
    }

    private func another() {
        guard let current, canAskAnother else { return }
        excludedIDs.insert(current.task.id)
        anotherCount += 1
        mentor?.lock()
        loadCurrent()
    }

    private func acceptMorning() {
        model.store.groupedUndo(String(localized: "morning.title")) {
            for entry in morningEntries {
                model.store.setDue(entry.task.id, day: today)
            }
        }
        model.didMutate()
        close()
    }

    private func close() {
        mentor?.lock()
        model.isImpulsOpen = false
    }

    /// Whether the morning card should be offered on this open of the app (spec §7.1 rules 2
    /// and 3 — rule 1's "3 eligible candidates" and rule 4's "Today/Inbox is active" are for
    /// the caller to check, since they need window state and the live pool count this screen
    /// does not otherwise compute up front).
    static func shouldOfferMorning(now: Date, lastShownDay: Int?) -> Bool {
        let today = Day.from(now, calendar: KronosLocale.calendar)
        return lastShownDay != today
    }
}
