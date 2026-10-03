// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols.
#if !RELEASE
// Kronos/Impuls/ImpulsSnapshots.swift — extra named screens for SnapshotHarness.
// All sample data is created lazily inside each view's `.onAppear` (never while this
// dictionary is being built): an eager mutation here would leak into every other screen
// registered in the same harness run.

import SwiftUI
import KronosCore

@MainActor
enum ImpulsSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "impuls": AnyView(ImpulsScreen(model: model)),
            "impuls.card": AnyView(
                SeededImpulsScreen(model: model, seed: .midCandidate, aiRouter: ImpulsFixtureRouting.sampleRouter())
            ),
            "impuls.card.dread": AnyView(SeededImpulsScreen(model: model, seed: .dreadCandidate)),
            "impuls.card.hrtitle": AnyView(SeededImpulsScreen(model: model, seed: .croatianTitle)),
            "impuls.empty": AnyView(SeededImpulsScreen(model: model, seed: .empty)),
            "impuls.card.generic": AnyView(SeededImpulsScreen(model: model, seed: .genericMove)),
            "impuls.morning": AnyView(SeededMorning(model: model)),
            "impuls.morning.sunday": AnyView(SeededMorning(model: model, sunday: true)),
            "impuls.nowcard": AnyView(SeededNowCard(model: model)),
        ]
    }
}

/// Seeds the store's OWN in-memory tasks on `.onAppear` (the harness already gives every
/// screen a fresh in-memory `TaskStore`, so writing here never touches anything else) and
/// then renders the real `ImpulsScreen` unmodified — the snapshot exercises the exact same
/// code path the app ships, not a stand-in.
private struct SeededImpulsScreen: View {
    enum Seed { case midCandidate, dreadCandidate, croatianTitle, genericMove, empty }

    let model: AppModel
    let seed: Seed
    var aiRouter: AIRouting? = nil
    @State private var didSeed = false

    var body: some View {
        ImpulsScreen(model: model, aiRouter: aiRouter)
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                plant()
                model.didMutate()
            }
    }

    /// These four screens each demonstrate ONE specific ranking outcome (a mid-energy pick,
    /// a dread opener, the true-empty state, three morning proposals). The harness always
    /// seeds the real 37-task import underneath every screen (gate-shots.mjs sets
    /// KRONOS_SEED unconditionally), so left alone those 37 tasks would compete with — and
    /// often outrank — whatever this file plants. Soft-deleting them here, inside this
    /// screen's own `.onAppear` and nowhere else, isolates the demonstration without
    /// touching the ranking engine or any other registered screen.
    private func plant() {
        for t in model.store.allTasks() { model.store.softDeleteNoUndo(t.id) }
        switch seed {
        case .midCandidate:
            let project = model.store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[6].color.hexString,
                                                     icon: "camera", area: nil)
            let task = model.store.create(title: "Objavi rujanski karusel", notes: "Mapa je na zajedničkom disku", project: project,
                                          status: .todo, priority: .none, dueDay: nil)
            model.store.setDepth(task.id, .shallow)
            model.store.setFirstMove(task.id, "Otvori Acme rujan mapu i preimenuj datoteku.")
        case .dreadCandidate:
            let task = model.store.create(title: "Reply to Alex about the unpaid invoice", notes: "", project: nil,
                                          status: .todo, priority: .none, dueDay: nil)
            model.store.setDread(task.id, true)
            model.store.setDepth(task.id, .shallow)
            // Left without a stored firstMove on purpose: exercises DeterministicFirstMove's
            // dread opener (spec §1.2/§2.3), which is what a real triage-less imported task hits.
        case .croatianTitle:
            // A Croatian title with notes and an estimate, no stored first move: the headline must
            // follow the APP language, and the estimate chip must not carry a tilde (audit D6/D25).
            let task = model.store.create(title: "ACME: na stranici \u{201E}Sve aktualne prilike ukratko\u{201C} maknuti stari tekst i dodati gumb za prijavu", notes: "Vidi bilješke", project: nil,
                                          status: .todo, priority: .none, dueDay: nil)
            model.store.setDepth(task.id, .shallow)
            model.store.update(task.id) { $0.estimateMinutes = 10 }
        case .genericMove:
            // A noun-phrase title with no stored move: the generator can only offer the generic
            // placeholder, so the title is the hero and there is no second line.
            let task = model.store.create(title: "Tax return for Globex", notes: "Accountant sent the forms on Monday", project: nil,
                                          status: .todo, priority: .none, dueDay: nil)
            model.store.setDepth(task.id, .shallow)
        case .empty:
            break   // no open tasks left -> the one calm empty line
        }
    }
}

/// The local `FixtureAIClient`-backed `AIRouting` used ONLY on the
/// "impuls.card" snapshot/debug path, to exercise ImpulsMentor's crossfade seam without a
/// network call. No production code path constructs one — production wires
/// the real router into `ImpulsScreen(aiRouter:)`.
enum ImpulsFixtureRouting {
    static func sampleRouter() -> AIRouting {
        let json = #"{"ranked":[{"position":1,"mentorLine":"Fifteen minutes, and the Acme folder is off the list."}]}"#
        let client = FixtureAIClient(modelID: "fixture", script: [.content(json)])
        return AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
    }
}
#endif
