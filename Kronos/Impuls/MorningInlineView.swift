// Kronos/Impuls/MorningInlineView.swift — the morning plan, shown INLINE above the list.
// Three proposals (max one deep), each a first move over its title. Return = Let's go: row 1 starts
// (in progress, pinned, cue) and the three are planned for today; no deadline is ever written.
// Escape or "Not today" dismisses. The card takes keyboard focus when it appears and gives it back
// the moment it closes; clicking into the list hands focus to the list as usual.

import SwiftUI
import KronosCore

/// The picks of the morning plan and what Let's go writes. Pure over the store and the day.
@MainActor
enum MorningPlan {
    /// Ranked pool: deep tasks allowed at any energy so the "max one deep" rule has something to
    /// diversify against; tasks set aside today are left out; relaxed if fewer than three remain.
    static func pool(model: AppModel, energy: KEnergyLevel, today: Int, engine: RankingProviding = RankingEngine()) -> [KTask] {
        let tasks = model.store.allTasks()
        let aside = ImpulsDayMemory.setAsideToday(among: tasks.map(\.id), today: today)
        let picks = ImpulsQuery.candidates(engine: engine, energy: energy, excluding: aside,
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

    /// Test hook: a live run cannot change the date, so it sets the weekday the card believes in.
    static var weekdayOverride: Int?

    /// Sundays the card also offers Sweep, the short review of what has gone quiet.
    static func offersSweepNow(now: Date = Date()) -> Bool {
        ImpulsDefaults.offersSweep(weekday: weekdayOverride ?? KronosLocale.calendar.component(.weekday, from: now))
    }

    /// Opens the Sweep sitting of the card flow.
    static func openSweep(model: AppModel) {
        TriageLaunch.shared.request(.sweep)
        model.isTriageOpen = true
    }

    /// Let's go: row 1 starts and every pick is planned for today, as ONE undo step. Only tasks that are
    /// not already in Today by deadline or plan get a write, and the deadline is never touched.
    static func letsGo(_ picks: [KTask], model: AppModel, today: Int) {
        guard let first = picks.first else { return }
        let rows = picks.map { ImpulsDefaults.PlanRow(id: $0.id, dueDay: $0.effectiveDue, plannedDay: $0.plannedDay) }
        let toPlan = ImpulsDefaults.idsNeedingPlan(rows, today: today)
        model.store.groupedUndo(String(localized: "morning.title")) {
            model.store.plan(toPlan, day: today)
            FocusStart.begin(first, model: model, followFirstMove: false)
        }
        model.didMutate()
        UndoToastCenter.shared.show(String(localized: "morning.undo.planned"))
    }
}

struct MorningInlineView: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var slots: [UUID] = []
    @State private var energy: KEnergyLevel = ImpulsEnergyMemory.current()
    @FocusState private var isFocused: Bool

    private var language: Lang { Lang(rawValue: KronosLocale.languageCode) ?? .en }
    private var today: Int { Day.today(calendar: KronosLocale.calendar) }

    private var pool: [KTask] { MorningPlan.pool(model: model, energy: energy, today: today) }

    /// The three on the card: the slots after a swap, else the top of the pool.
    private var picks: [KTask] {
        let all = pool
        let ids = slots.isEmpty ? Array(all.prefix(3)).map(\.id) : slots
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    var body: some View {
        let _ = model.version
        let current = picks
        VStack(alignment: .leading, spacing: Space.x4) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(String(localized: "morning.title"))
                    .font(Typo.heading)
                    .foregroundStyle(Tok.textPrimary)
                Text(String(localized: "morning.subtitle"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            VStack(spacing: Space.x2) {
                ForEach(Array(current.enumerated()), id: \.element.id) { index, task in
                    row(task, index: index)
                }
            }
            HStack {
                Button(String(localized: "morning.dismiss"), action: onClose)
                    .kButton(.ghost)
                    .uiTestAnchor("morning.dismiss")
                if MorningPlan.offersSweepNow() {
                    Button(String(localized: "sweep.command")) {
                        MorningPlan.openSweep(model: model)
                        onClose()
                    }
                    .kButton(.ghost)
                    .uiTestAnchor("morning.sweep")
                }
                Spacer()
                Button(String(localized: "morning.accept"), action: letsGo)
                    .kButton(.primary)
                    // Return is Let's go while the card has the focus (its default button); with
                    // the focus anywhere else, Return keeps its own meaning there.
                    .keyboardShortcut(isFocused ? .defaultAction : nil)
                    .disabled(current.isEmpty)
                    .uiTestAnchor("morning.letsgo")
            }
        }
        .padding(Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.bg)
        .kBorder(Tok.borderControl, radius: Radius.card)
        .padding(.horizontal, Space.x4)
        .padding(.top, Space.x3)
        .padding(.bottom, Space.x2)
        .accessibilityElement(children: .contain)
        .uiTestAnchor("morning.card")
        .focusable(true)
        .focusEffectDisabled()
        .focused($isFocused)
        // Return is Let's go's own shortcut above. Esc is the exit command: with the card focused
        // it closes the card (the most specific handler wins over the shell's Esc cascade).
        // `a` and the right arrow belong to Pick one, not to this card.
        .onExitCommand(perform: onClose)
        .onAppear {
            energy = ImpulsEnergyMemory.current()
            isFocused = true
        }
        .task {
            // The list below also asks for focus as it mounts (its new-task field takes the caret),
            // and on a busy Mac that can land after the first 150 ms: look a few times, and when that
            // field holds the caret take it back, or Esc and Return would go to it.
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(150))
                if !model.isAnyOverlayOpen, let window = NSApp.keyWindow,
                   let field = window.firstResponder as? NSTextView, field.accessibilityLabel() == String(localized: "list.new") {
                    window.makeFirstResponder(nil)
                    isFocused = false
                    await Task.yield()
                }
                isFocused = true
            }
        }
    }

    private func row(_ task: KTask, index: Int) -> some View {
        let hero = ImpulsQuery.hero(for: task, language: language)
        return HStack(alignment: .center, spacing: Space.x2) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(hero.hero)
                    .font(Typo.rowStrong)
                    .foregroundStyle(Tok.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary = hero.secondary {
                    Text(secondary)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Swaps THIS slot for the next unshown candidate; never re-ranks, never writes.
            Button { swap(index) } label: { Icon("repeat", size: Metrics.iconS) }
                .kButton(.icon)
                .accessibilityLabel(String(localized: "morning.swap"))
                .help(String(localized: "morning.swap"))
        }
        .accessibilityElement(children: .combine)
    }

    private func swap(_ index: Int) {
        let all = pool
        var ids = slots.isEmpty ? Array(all.prefix(3)).map(\.id) : slots
        guard index < ids.count, let next = all.first(where: { !ids.contains($0.id) }) else { return }
        ids[index] = next.id
        slots = ids
    }

    private func letsGo() {
        MorningPlan.letsGo(picks, model: model, today: today)
        onClose()
    }
}

/// The list column with the morning plan above it, exactly as the window composes it. The shell and
/// the snapshot both use this, so what a snapshot shows is what the window shows.
struct ListWithMorningPlan: View {
    let model: AppModel
    @Binding var showsMorning: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsMorning {
                MorningInlineView(model: model, onClose: { showsMorning = false })
                KHairline()
            }
            TaskListScreen(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
