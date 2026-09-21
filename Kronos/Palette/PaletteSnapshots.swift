// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols without touching any
// file this leaf does not own.
#if !RELEASE
// Kronos/Palette/PaletteSnapshots.swift
// Named screens for Kronos/Shared/SnapshotHarness.swift. Seeding (query text, selection)
// happens in the returned view's .onAppear, never while this dictionary is built —
// CommandPaletteView's own .onAppear does the seeding here, so this file only wires arguments.
import SwiftUI

@MainActor
enum PaletteSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "palette": AnyView(CommandPaletteView(model: model, initialQuery: "")),
            // "ka" matches the Create/Go-to project and task titles seeded from
            // kronos-seed.json's 37 real tasks, giving a mixed commands+project+tasks result.
            // A task selection is seeded first (task-scoped commands — Pin, Break down — are
            // `isAvailable` only with one) so this screen also demonstrates those rows, not
            // just the empty-selection default set.
            "palette.results": AnyView(SeededSelectionPaletteView(model: model)),
            "palette.empty": AnyView(CommandPaletteView(model: model, initialQuery: "zzzznotarealmatchxyz")),
            "palette.keymap": AnyView(KeymapReferenceView(onClose: {})),
            // Shows the shortcuts card already filtered (search field seeded via
            // KeymapReferenceView's own snapshot-only `initialQuery`, same pattern as
            // `palette`/`palette.results` above using CommandPaletteView's).
            "palette.keymap.search": AnyView(KeymapReferenceView(onClose: {}, initialQuery: "isključi")),
            // A task selection is seeded (same reason as palette.results: "Re-triage"/"Link
            // Apple note" are `isAvailable` only with one). "Switch to block project"/"Stay"
            // stay absent here — they need `model.coach.blockSuggestion`, which only a real
            // calendar event or a CoachModel fixture seam (neither owned by this leaf) can
            // produce; reported as a gap rather than faked.
            "palette.coach": AnyView(SeededCoachPaletteView(model: model)),
        ]
    }
}

/// Seeds a task selection on `.onAppear` and filters to "coach" — `PaletteMatcher.bestScore`
/// matches a command's title OR its group's raw `titleKey`, and every coach command shares
/// `group.titleKey == "palette.section.coach"`, so this query surfaces the WHOLE coach group
/// (ledger: "a query that shows the coach group") rather than one command inside it.
private struct SeededCoachPaletteView: View {
    let model: AppModel
    @State private var didSeed = false

    var body: some View {
        CommandPaletteView(model: model, initialQuery: "coach")
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                if model.selectedTaskID == nil {
                    model.selectedTaskID = model.store.allTasks().first?.id
                }
            }
    }
}

/// Seeds `model.selectedTaskID` to the store's first task on `.onAppear` (never while the
/// screens dictionary is being built) so the "ka"-filtered results screen renders
/// with a real selection and its task-scoped commands available, then renders the real
/// `CommandPaletteView` unmodified.
private struct SeededSelectionPaletteView: View {
    let model: AppModel
    var query: String = "ka"
    @State private var didSeed = false

    var body: some View {
        CommandPaletteView(model: model, initialQuery: query, selectFirstTask: true)
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                if model.selectedTaskID == nil {
                    model.selectedTaskID = model.store.allTasks().first?.id
                }
            }
    }
}
#endif
