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
            // G3: the queue is empty — every task already has priority/effort/deadline/project.
            "triage.empty": AnyView(EmptyTriageFlow(model: model)),
        ]
    }
}

private struct SeededTriageFlow: View {
    let model: AppModel
    var startWithDateEditing = false
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                TriageFlowView(model: model, onClose: {}, startWithDateEditing: startWithDateEditing)
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
            _ = model.store.create(title: "Send the Acme proposal", notes: "", project: nil,
                                   status: .todo, priority: .none, dueDay: nil)
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
