// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols without touching any
// file this leaf does not own.
#if !RELEASE
// Kronos/Triage/TriageSnapshots.swift
// Named screens for Kronos/Shared/SnapshotHarness.swift. Seeding happens in the returned
// view's `.onAppear`, never while this dictionary is built.
import SwiftUI
import KronosCore

@MainActor
enum TriageSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            // G3/G4: one bare task at the front of the queue, suggestion prefilled from two
            // similar Acme neighbours so the reason line and every prefilled field render.
            "triage.card": AnyView(SeededTriageFlow(model: model)),
            // G4: same fixture, with the typed-date field already open (G5 "deadline mora
            // imat opciju da upisem datum isto") — a static render cannot press D itself.
            "triage.card.date": AnyView(SeededTriageFlow(model: model, startWithDateEditing: true)),
            // The ⌥ legend open (field keys + plan keys) on a task planned for today.
            "triage.card.keys": AnyView(SeededTriageFlow(model: model, planToday: true, legendOpen: true)),
            // "AI is not set up": the router has no usable provider, so the line is a link to Settings.
            "triage.card.ai.setup": AnyView(SeededTriageFlow(model: model, noKeyRouter: true)),
            // G3: the queue is empty — every task already has priority/effort/deadline/project.
            "triage.empty": AnyView(EmptyTriageFlow(model: model)),
            // Five cards handled: the end-of-sitting panel with "Do 5 more".
            "triage.session": AnyView(SessionDoneFlow(model: model)),
            // Sweep: three old tasks (someday, waiting, open) seeded; the oldest is the first card.
            "triage.sweep": AnyView(SeededSweepFlow(model: model)),
            // Sweep with nothing old: the seeded fixture was touched just now.
            "triage.sweep.empty": AnyView(SweepFlow(model: model)),
        ].merging(ReviewSnapshots.screens(model: model)) { a, _ in a }
    }
}

private struct SeededTriageFlow: View {
    let model: AppModel
    var startWithDateEditing = false
    var planToday = false
    var legendOpen = false
    var noKeyRouter = false
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                TriageFlowView(model: model, onClose: {}, startWithDateEditing: startWithDateEditing,
                               startLegendOpen: legendOpen)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            let project = model.store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[10].hex, icon: "briefcase", area: nil)
            // Two similar, fully-triaged neighbours so NeighbourTriage's vote clears its
            // agreement threshold and the card shows a real "Like 2 similar Acme tasks" reason.
            for title in ["Send the Acme kickoff recap", "Send the Acme renewal recap"] {
                let neighbour = model.store.create(title: title, notes: "", project: project,
                                                   status: .done, priority: .high, dueDay: nil)
                model.store.setEffort(neighbour.id, .m)
            }
            // The bare task the queue will show first — missing all four fields, oldest.
            let bare = model.store.create(title: "Send the Acme proposal", notes: "", project: nil,
                                          status: .todo, priority: .none, dueDay: nil)
            // The gate's fixture holds older untriaged tasks: plan the one that is really first.
            if planToday, let first = TriageQueue.ordered(in: model.store.allTasks()).first {
                model.store.plan(first.id, day: Day.today(calendar: KronosLocale.calendar))
            }
            _ = bare
            if noKeyRouter { model.ai = NoKeyRouter() }
            model.didMutate()
            didSeed = true
        }
    }
}

/// A router with no usable provider: every triage ask throws, which the card reads as "AI is not set up".
private struct NoKeyRouter: AIRouting {
    func triage(title: String, notes: String, projectNames: [String], labelNames: [String], today: Int,
                lockedFields: Set<String>, context: TriageContext) async throws -> TriageResult { throw AIError.noUsableProvider }
    func retriage(title: String, notes: String, previous: TriageResult, feedback: String,
                  projectNames: [String], labelNames: [String], today: Int) async throws -> TriageResult { previous }
    func impulsPick(candidates: [Candidate], energy: KEnergyLevel, language: String) async throws -> ImpulsRanking { ImpulsRanking(ranked: []) }
    func ordoResort(queueTitles: [String], message: String, history: [String], language: String) async throws -> OrdoResort { .unchanged(queueCount: 0) }
    func extractTasks(from text: String, projectNames: [String], existingOpenTitles: [String], today: Int) async -> ExtractResult {
        ExtractResult(tasks: [], droppedLineCount: 0, isDeterministic: true, reason: .aiOff)
    }
    func breakdown(title: String, notes: String, existingSubtasks: [String]) async -> BreakdownResult {
        BreakdownResult(subtasks: [], firstMove: "", isDeterministic: true)
    }
}

private struct SessionDoneFlow: View {
    let model: AppModel
    var body: some View {
        TriageFlowView(model: model, onClose: {}, startMode: .sort, startHandled: TriageSession.size)
    }
}

private struct SweepFlow: View {
    let model: AppModel
    var body: some View {
        TriageFlowView(model: model, onClose: {}, startMode: .sweep)
    }
}

private struct SeededSweepFlow: View {
    let model: AppModel
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                TriageFlowView(model: model, onClose: {}, startMode: .sweep)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            let now = Date()
            @MainActor func aged(_ title: String, _ status: KStatus, daysIdle: Int) {
                let task = model.store.create(title: title, notes: "", project: nil,
                                              status: status, priority: .none, dueDay: nil)
                model.store.updateNoUndo(task.id) { $0.updatedAt = now.addingTimeInterval(-Double(daysIdle) * 86_400) }
            }
            aged("Renew the domain", .todo, daysIdle: 30)
            aged("Ask Marta about the contract", .waiting, daysIdle: 9)
            aged("Read the Sparkle release notes", .someday, daysIdle: 23)
            model.didMutate()
            didSeed = true
        }
    }
}

/// The gate always seeds the real 37-task fixture (`scripts/gate-shots.mjs`), so an actually
/// empty queue means filling in whatever every one of THOSE tasks is still missing, not
/// creating a single already-complete task alongside 37 untouched ones.
private struct EmptyTriageFlow: View {
    let model: AppModel
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                TriageFlowView(model: model, onClose: {})
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            let fallbackProject = model.store.allProjects().first
                ?? model.store.createProject(name: "Globex", colorHex: KProjectPalette.swatches[6].hex, icon: "briefcase", area: nil)
            for t in model.store.allTasks() where TriageQueue.isMissingData(t) {
                if t.priority == .none { model.store.setPriority(t.id, .medium) }
                if t.effort == .none { model.store.setEffort(t.id, .m) }
                if t.dueDay == nil { model.store.setDue(t.id, day: 999_999) }
                if t.project == nil { model.store.move(t.id, toProject: fallbackProject) }
            }
            model.didMutate()
            didSeed = true
        }
    }
}
#endif
