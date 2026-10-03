// Kronos/Impuls/ImpulsScreen.swift
//
// ONE task, ranked for the energy you have today. The card shows at once from the energy chosen
// today (else a time-of-day default); energy is a small chip under the card, not a question before it.
// Rendered synchronously from RankingEngine (<=100ms); the AI, if wired, may only crossfade the
// mentor line within a 4s budget and can never change the task on screen (ImpulsMentor.swift owns
// that seam). No red, no timers, no streaks, no "!" anywhere.

import SwiftUI
import KronosCore

struct ImpulsScreen: View {
    let model: AppModel
    /// Injected once a real router exists; nil (the default everywhere in this file) means
    /// Impuls runs fully offline — every line the user sees is generic.
    var aiRouter: AIRouting? = nil
    var engine: RankingProviding = RankingEngine()

    init(model: AppModel, aiRouter: AIRouting? = nil, engine: RankingProviding = RankingEngine()) {
        self.model = model
        self.aiRouter = aiRouter
        self.engine = engine
    }

    @State private var energy: KEnergyLevel = ImpulsEnergyMemory.current()
    @State private var energyOpen = false
    @State private var excludedIDs: Set<UUID> = []
    @State private var anotherCount = 0
    @State private var current: ImpulsCard?
    @State private var mentor: ImpulsMentor?
    /// The dread memory as it was BEFORE the card on screen was picked. A re-rank caused by a store
    /// change reuses it, so the same card comes back; only a new pick (open, Another, energy change)
    /// reads the memory afresh.
    @State private var servingBase = ImpulsDreadMemory.load()
    @FocusState private var isFocused: Bool

    private var language: Lang { Lang(rawValue: KronosLocale.languageCode) ?? .en }
    private var today: Int { Day.today(calendar: KronosLocale.calendar) }

    var body: some View {
        ZStack {
            Tok.bg
            VStack(spacing: Space.x4) {
                content
                if current != nil { energyBlock }
            }
            .padding(Space.x6)
            .frame(maxWidth: Metrics.impulsCardWidth)
        }
        // Hugs its content: a full-height black column with empty bands above and below the
        // card read as a broken screen; the shell centres it.
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .focusable(true)
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            energy = ImpulsEnergyMemory.current()
            ImpulsDayMemory.prune(today: today, liveTaskIDs: Set(model.store.allTasks().map(\.id)))
            newPick()
        }
        .task {
            // The list and inspector also ask for focus as they mount; take it back once they have,
            // so Return and the digit keys reach this card.
            try? await Task.sleep(for: .milliseconds(150))
            isFocused = true
        }
        // Re-evaluate on every store mutation (SwiftData models are read via manual fetches, never
        // @Query). A parent that seeds sample data in ITS OWN `.onAppear` runs after this one, so
        // without this the very first render would be built from whatever was there before the seed.
        .onChange(of: model.version) { _, _ in reload() }
        .onKeyPress("1") { setEnergy(.low); return .handled }
        .onKeyPress("2") { setEnergy(.mid); return .handled }
        .onKeyPress("3") { setEnergy(.high); return .handled }
        .onKeyPress(.return) { start(); return .handled }
        .onKeyPress(.rightArrow) { another(); return .handled }
        .onKeyPress("a") { another(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    // MARK: Energy

    /// Remembered on every change (not only on Start) so a change survives the next open. The same
    /// value feeds the morning plan: there is one energy for the day.
    private func setEnergy(_ level: KEnergyLevel) {
        guard energy != level else { return }
        energy = level
        ImpulsEnergyMemory.rememberToday(level)
        newPick()
    }

    private func energyName(_ level: KEnergyLevel) -> String {
        switch level {
        case .low: String(localized: "energy.low")
        case .mid: String(localized: "energy.mid")
        case .high: String(localized: "energy.high")
        }
    }

    private var energyBlock: some View {
        VStack(spacing: Space.x2) {
            HStack(spacing: Space.x2) {
                Text(String(localized: "impuls.energy.prompt"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
                KChip(energyName(energy), trailing: .chevron, onTap: {
                    withAnimation(Motion.select) { energyOpen.toggle() }
                })
                .uiTestAnchor("impuls.energy.chip")
            }
            if energyOpen {
                KSegmented(selection: Binding(get: { energy }, set: { setEnergy($0) }), segments: [
                    KSegment(value: KEnergyLevel.low, text: String(localized: "energy.low")),
                    KSegment(value: KEnergyLevel.mid, text: String(localized: "energy.mid")),
                    KSegment(value: KEnergyLevel.high, text: String(localized: "energy.high")),
                ], style: .fill)
            }
        }
    }

    // MARK: Content — the card or the empty line

    @ViewBuilder
    private var content: some View {
        if let current, let mentor {
            let hero = ImpulsQuery.hero(for: current.task, language: language)
            ImpulsCardView(card: current, mentor: mentor, hero: hero,
                           leftOff: LeftOffLine.text(for: current.task, hero: hero.hero),
                           showsAnother: showsAnother,
                           onStart: start, onAnother: another, onNotNow: notNow)
        } else {
            KEmptyState(icon: "check-square", title: String(localized: "impuls.empty.line"))
                .frame(maxWidth: .infinity)
                .uiTestAnchor("impuls.empty")
        }
    }

    // MARK: Ranking + mentor lifecycle

    private var showsAnother: Bool {
        ImpulsDefaults.showsAnother(used: anotherCount, hasNext: !nextCandidatesWouldBeEmpty)
    }

    private var nextCandidatesWouldBeEmpty: Bool {
        guard let current else { return true }
        var excl = excludedIDs.union(setAsideToday)
        excl.insert(current.task.id)
        return ImpulsQuery.candidates(engine: engine, energy: energy, excluding: excl,
                                      tasks: model.store.allTasks(), today: today, count: 1).isEmpty
    }

    private var setAsideToday: Set<UUID> {
        ImpulsDayMemory.setAsideToday(among: model.store.allTasks().map(\.id), today: today)
    }

    /// A new pick (open, Another, energy change): read the dread memory afresh, then rank.
    private func newPick() {
        mentor?.lock()
        servingBase = ImpulsDreadMemory.load()
        loadCurrent()
    }

    /// A store change: same memory, same pool, so the same card comes back.
    private func reload() {
        mentor?.lock()
        loadCurrent()
    }

    private func loadCurrent() {
        let tasks = model.store.allTasks()
        let aside = ImpulsDayMemory.setAsideToday(among: tasks.map(\.id), today: today)
        let picks = ImpulsQuery.candidates(engine: engine, energy: energy, excluding: excludedIDs.union(aside),
                                           tasks: tasks, today: today, count: 5, dreadServing: servingBase)
        guard let top = picks.first, let task = tasks.first(where: { $0.id == top.taskID }) else {
            current = nil
            mentor = nil
            return
        }
        // A Large task with no steps gets its steps now, silently, so step 1 is the first move.
        if ImpulsAutoBreakdown.runIfNeeded(task, store: model.store) { model.didMutate() }
        // The pick is remembered the moment it is shown: once a day, never twice in a row.
        ImpulsDreadMemory.save(servingBase.recording(top, today: today))
        let generic = ImpulsQuery.genericMentorLine(for: task, candidateReason: top.reason, energy: energy)
        current = ImpulsCard(task: task, mentorLine: generic)
        let m = ImpulsMentor(generic: generic)
        mentor = m
        m.requestRefinement(router: aiRouter, candidates: picks, shownTaskID: task.id,
                            energy: energy, language: language.rawValue)
    }

    // MARK: Actions

    private func start() {
        guard let current else { return }
        mentor?.lock()
        FocusStart.begin(current.task, model: model, followFirstMove: true)
        ImpulsEnergyMemory.rememberToday(energy)
        close()
    }

    private func another() {
        guard let current, showsAnother else { return }
        excludedIDs.insert(current.task.id)
        anotherCount += 1
        newPick()
    }

    /// Leaves this task out of Pick one and the morning plan for the rest of today, then closes.
    private func notNow() {
        guard let current else { return }
        ImpulsDayMemory.setAside(current.task.id, today: today)
        close()
    }

    private func close() {
        mentor?.lock()
        model.isImpulsOpen = false
    }
}
