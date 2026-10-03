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
            // The fixed card, editor and palette keys, narrowed by a key cap.
            "palette.keymap.cards": AnyView(KeymapReferenceView(onClose: {}, initialQuery: "⏎")),
            "palette.keymap.search": AnyView(KeymapReferenceView(onClose: {}, initialQuery: "isključi")),
            // A task selection is seeded (same reason as palette.results: "Re-triage"/"Link
            // Apple note" are `isAvailable` only with one). "Switch to block project"/"Stay"
            // stay absent here — they need `model.coach.blockSuggestion`, which only a real
            // calendar event or a CoachModel fixture seam (neither owned by this leaf) can
            // produce; reported as a gap rather than faked.
            // The task rows with their "Due date" qualifier and key caps from the registry.
            "palette.rows": AnyView(SeededSelectionPaletteView(model: model, query: "due")),
            // The second steps: a typed date phrase, a project name, the current title.
            "palette.prompt.date": AnyView(SeededPromptView(model: model, kind: .pickDate, query: "fri")),
            "palette.prompt.move": AnyView(SeededPromptView(model: model, kind: .moveTo, query: "")),
            "palette.prompt.rename": AnyView(SeededPromptView(model: model, kind: .rename, query: "A clearer title")),
            "palette.bulk": AnyView(SeededBulkPaletteView(model: model)),
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

/// One of the palette's second steps over the store's first task, in the card's own chrome.
private struct SeededPromptView: View {
    enum Kind { case pickDate, moveTo, rename }
    let model: AppModel
    let kind: Kind
    let query: String
    @State private var didSeed = false

    private var taskID: UUID { model.store.allTasks().first?.id ?? UUID() }

    var body: some View {
        let prompt: PalettePrompt = {
            switch kind {
            case .pickDate: return .pickDate(taskID)
            case .moveTo: return .moveTo(taskID)
            case .rename: return .rename(taskID)
            }
        }()
        PalettePromptView(model: model, prompt: prompt, onBack: {}, initialQuery: query)
            .background(Tok.overlay)
            .kBorder(Tok.borderControl, radius: Radius.popover)
            .clipShape(RoundedRectangle(cornerRadius: Radius.popover, style: .continuous))
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                if model.selectedTaskID == nil { model.selectedTaskID = model.store.allTasks().first?.id }
            }
    }
}

/// Two rows selected and the query "tasks": the whole "Selected tasks" group shows, Delete last (audit D14).
private struct SeededBulkPaletteView: View {
    let model: AppModel
    @State private var didSeed = false

    var body: some View {
        CommandPaletteView(model: model, initialQuery: "palette.bulk")
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                let ids = model.store.allTasks().prefix(3).map(\.id)
                model.selectedTaskID = ids.first
                model.selectedIDs = Set(ids)
            }
    }
}
#endif
