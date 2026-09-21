// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols without touching any
// file this leaf does not own.
#if !RELEASE
// Named screens the snapshot harness can render for this leaf, beyond the built-in
// "inspector". Popovers can't be captured while presented, so the recurrence picker's
// CONTENT is exposed directly as its own screen.
import SwiftUI
import KronosCore

enum DetailSnapshots {
    @MainActor
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "inspector.recurrence": AnyView(
                KPanel {
                    InspectorRecurrenceEditor(
                        rule: .weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay),
                        locale: KronosLocale.languageCode
                    ) { _ in }
                }
                .padding(Space.x4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Tok.bg)
            ),
            // Registry construction must not mutate the store (it runs for every screen,
            // not just this one) — the seed task and its four steps are created in
            // StepsSnapshotHost's own .onAppear instead.
            "inspector.steps": AnyView(StepsSnapshotHost(model: model)),
            // Break down preview, no existing subtasks: 5-step AI result plus the
            // first-move offer row (task starts with no first move).
            "inspector.breakdown": AnyView(BreakdownSnapshotHost(model: model, seedExistingSubtasks: false)),
            // Break down preview with 2 existing subtasks (one done) above a 4-step
            // proposal — proves existing rows render untouched above the preview.
            "inspector.breakdown.existing": AnyView(BreakdownSnapshotHost(model: model, seedExistingSubtasks: true)),
            // G3: the triage-filled line + Re-triage, and the note-link/context-link chips.
            // Both drive InspectorScreen's snapshot-only preview parameters directly (the
            // live `AppDelegate.shared` and `model.notes` osascript path are unreachable from
            // a harness process — see InspectorCoachSection.swift's doc comment) rather than
            // seeding through the real service.
            "inspector.triaged": AnyView(TriagedSnapshotHost(model: model)),
            "inspector.links": AnyView(LinksSnapshotHost(model: model)),
            // The "Vremenski blok" row (InspectorCalendarBlockRow). `model.coach` always
            // wraps the real `EventKitCalendar()` (UIContract.swift — no fixture-injection
            // seam reaches this row), so a harness process shows whatever that machine's
            // actual, never-prompted Calendar authorization status is — the calm "Allow
            // access" row on a machine that has never granted Kronos access, which is itself
            // the real state this row must prove it renders correctly.
            "inspector.block": AnyView(BlockSnapshotHost(model: model)),
            // Accordion open. See `InspectorCalendarBlockRow.forceExpandedOnAppear`'s doc
            // comment: proves the disclosure chrome, not fake seeded blocks (no fixture seam
            // for todaysBlocks).
            "inspector.block.open": AnyView(BlockSnapshotHost(model: model, forceExpanded: true)),
            // The Notes compact card — a linked note with a real multi-line body through
            // FixtureNotesBridge, so the 2-line summary actually has text to show.
            "inspector.note": AnyView(NoteCardSnapshotHost(model: model)),
            // The unlinked state, proving the button reads as a button (bordered, glyph) at
            // the property-row position rather than a plain-text row.
            "inspector.notelink.unlinked": AnyView(UnlinkedNoteSnapshotHost(model: model)),
            // The picker's own three states — loaded (folder already selected, several
            // notes, most-recent-first), empty (a real folder with nothing in it) and denied
            // (Automation access not granted) — exposed as sheet CONTENT directly, the same
            // reason capture.notes/capture.notes.denied do (CaptureSnapshots.swift: "popovers/
            // sheets can't be captured while presented").
            "inspector.notelink.picker": AnyView(NoteLinkPickerSnapshotHost(model: model, state: .loaded)),
            "inspector.notelink.picker.empty": AnyView(NoteLinkPickerSnapshotHost(model: model, state: .empty)),
            "inspector.notelink.picker.denied": AnyView(NoteLinkPickerSnapshotHost(model: model, state: .denied)),
        ]
    }
}

/// A task with a filled priority + effort, shown with a fixed `TriageFillDisplay` standing in
/// for the live `AutoTriage.Fill` the real screen would read from `AppDelegate.shared`.
private struct TriagedSnapshotHost: View {
    let model: AppModel
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                InspectorScreen(model: model, previewTriageFill: .some(TriageFillDisplay(
                    fields: [.priority, .effort],
                    reason: String(localized: "triage.preview.reason"))))
                    .onAppear { model.selectedTaskID = task.id }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            let project = model.store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[6].hex, icon: "briefcase", area: nil)
            let seeded = model.store.create(title: "Send the Acme kickoff recap", notes: "", project: project,
                                            status: .todo, priority: .high, dueDay: nil)
            model.store.setEffort(seeded.id, .m)
            task = seeded
        }
    }
}

/// A task with one Apple Note link and one context link (a web URL) — the three link kinds
/// are Apple Note / file / web; a folder or plain-text drop resolves to `.file`/`.web` at the
/// point `ListDrop.swift` writes the `ContextLink`, so this
/// one task's two rows exercise both the note-link row and the context-link chip in the SAME
/// screen (Apple Note here, web link separately) — a task carries at most one of each kind at
/// once (ContextLink/NoteLink's own "replace, don't accumulate" contract), so a single task
/// showing both rows together is the real maximum state, not a partial one.
private struct LinksSnapshotHost: View {
    let model: AppModel
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                InspectorScreen(model: model)
                    .onAppear { model.selectedTaskID = task.id }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            model.notes = FixtureNotesBridge(bodiesByID: ["fixture-note-id": "Renewal talking points\nPricing holds through Q4."])
            let seeded = model.store.create(title: "Prep the Acme renewal deck", notes: "", project: nil,
                                            status: .todo, priority: .none, dueDay: nil)
            model.store.update(seeded.id) { t in
                var notes = NoteLink.appending("fixture-note-id", to: t.notes)
                notes = ContextLink(kind: .web, reference: "https://example.com/brief", displayName: "example.com/brief")
                    .appending(to: notes)
                t.notes = notes
            }
            model.didMutate()
            task = seeded
        }
    }
}

/// Seeds one task (with or without two existing subtasks) purely on
/// .onAppear, then shows the real InspectorStepsSection with its Break down
/// preview forced open via a fixed `BreakdownResult` — never `model.ai`, so
/// the harness renders synchronously with no network and no live async task.
private struct BreakdownSnapshotHost: View {
    let model: AppModel
    let seedExistingSubtasks: Bool
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                KPanel {
                    InspectorStepsSection(model: model, task: task,
                                          forceBreakdownPreview: fixedResult)
                }
                .padding(Space.x4)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            let seeded = model.store.create(title: "Plan the Zagreb offsite", notes: "",
                                             project: nil, status: .todo, priority: .none, dueDay: nil)
            if seedExistingSubtasks {
                model.store.addSubtask(seeded.id, title: "Pick a date")
                model.store.addSubtask(seeded.id, title: "Book the venue")
                let existing = seeded.orderedSubtasks
                if let first = existing.first { model.store.toggleSubtask(first.id) }
            }
            task = seeded
        }
    }

    private var fixedResult: BreakdownResult {
        seedExistingSubtasks
            ? BreakdownResult(subtasks: [
                "Draft the agenda", "Invite the team", "Confirm catering", "Send the calendar hold"
              ], firstMove: "Draft the agenda", isDeterministic: false)
            : BreakdownResult(subtasks: [
                "List everyone attending", "Pick a date", "Book the venue",
                "Draft the agenda", "Send the calendar hold"
              ], firstMove: "List everyone attending", isDeterministic: false)
    }
}

/// A plain task (no calendar link) selected in the real InspectorScreen — exercises
/// InspectorCalendarBlockRow exactly as the live screen would show it.
private struct BlockSnapshotHost: View {
    let model: AppModel
    var forceExpanded: Bool = false
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                InspectorScreen(model: model, previewCalendarBlockExpanded: forceExpanded)
                    .onAppear { model.selectedTaskID = task.id }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            let seeded = model.store.create(title: "Review the Globex proposal", notes: "", project: nil,
                                            status: .todo, priority: .none, dueDay: nil)
            task = seeded
        }
    }
}

/// The Notes-block compact card (`InspectorNoteLinkRow`'s linked-state `KPanel`): a task
/// linked to a note with a real multi-line body via `FixtureNotesBridge`, so the title +
/// 2-line summary both have real content to render (not an empty/placeholder state).
private struct NoteCardSnapshotHost: View {
    let model: AppModel
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                InspectorScreen(model: model)
                    .onAppear { model.selectedTaskID = task.id }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            model.notes = FixtureNotesBridge(bodiesByID: [
                "fixture-note-card": "Q3 renewal call\nCustomer wants a discount on the annual plan.\nFollow up with pricing by Friday.",
            ])
            let seeded = model.store.create(title: "Prep the Globex renewal call", notes: "", project: nil,
                                            status: .todo, priority: .none, dueDay: nil)
            model.store.update(seeded.id) { t in
                t.notes = NoteLink.appending("fixture-note-card", to: t.notes)
            }
            model.didMutate()
            task = seeded
        }
    }
}

/// Seeds one task with four steps (two done) and selects it, purely on .onAppear, then
/// shows the real InspectorStepsSection with its first step forced into rename mode.
private struct StepsSnapshotHost: View {
    let model: AppModel
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                KPanel {
                    InspectorStepsSection(model: model, task: task, forceRenameOnAppear: true)
                }
                .padding(Space.x4)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            let seeded = model.store.create(title: "Steps snapshot", notes: "", project: nil,
                                             status: .todo, priority: .none, dueDay: nil)
            // The harness renders a FIXED 420x860 canvas regardless of this view's own frame,
            // so a compact top-aligned panel's ink share depends only on how many rows it
            // draws. Five rows measured 1.48% — under the ledger's 2% floor (gate-shots.mjs)
            // — so this needed real added content, not a resized/reflowed container: nine
            // rows (one more than the visible list needs to prove reorder-button disabling at
            // both ends) push the same single-line rows past the floor.
            for title in ["Draft outline", "Research competitors", "Send for review", "Revise",
                          "Get sign-off", "Publish", "Announce internally", "Archive notes", "Retro notes"] {
                model.store.addSubtask(seeded.id, title: title)
            }
            let steps = seeded.orderedSubtasks
            if steps.count >= 2 {
                model.store.toggleSubtask(steps[0].id)
                model.store.toggleSubtask(steps[1].id)
            }
            task = seeded
        }
    }
}

/// The unlinked note-link row/button, at the real InspectorScreen position — a plain
/// task with no `NoteLink` in its notes, so `InspectorNoteLinkRow` renders the bordered "Link
/// Apple note" button rather than the linked card `NoteCardSnapshotHost` above exercises.
private struct UnlinkedNoteSnapshotHost: View {
    let model: AppModel
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                InspectorScreen(model: model)
                    .onAppear { model.selectedTaskID = task.id }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            model.notes = FixtureNotesBridge()
            let seeded = model.store.create(title: "Prep the Initech kickoff", notes: "", project: nil,
                                            status: .todo, priority: .none, dueDay: nil)
            task = seeded
        }
    }
}

/// `NotesPickerSheet`'s own content exposed directly (sheets can't be captured while
/// presented, same reason `CaptureSnapshots.swift`'s `NotesPickerHost` exists) — `.loaded` opens
/// straight into a folder with several notes via `initialFolder` (search already has something
/// real to filter); `.empty` opens into a folder with zero notes; `.denied` shows the shared
/// calm allow state through `FixtureNotesBridge(errorToThrow: .notAuthorised)`.
private struct NoteLinkPickerSnapshotHost: View {
    enum State { case loaded, empty, denied }
    let model: AppModel
    let state: State
    @State private var didSeed = false

    private static let folder = NoteFolderInfo(id: "f1", name: "Kronos")

    var body: some View {
        Group {
            if didSeed {
                NotesPickerSheet(model: model, mode: .single { _, _ in },
                                 initialFolder: state == .denied ? nil : Self.folder)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            switch state {
            case .loaded:
                model.notes = FixtureNotesBridge(folders: [Self.folder], notesByFolder: [Self.folder.name: [
                    NoteInfo(id: "n1", title: "Acme kickoff recap", modifiedAt: Date()),
                    NoteInfo(id: "n2", title: "Globex onboarding", modifiedAt: Date().addingTimeInterval(-3600)),
                    NoteInfo(id: "n3", title: "Initech renewal notes", modifiedAt: Date().addingTimeInterval(-2 * 86_400)),
                ]])
            case .empty:
                model.notes = FixtureNotesBridge(folders: [Self.folder], notesByFolder: [Self.folder.name: []])
            case .denied:
                model.notes = FixtureNotesBridge(errorToThrow: .notAuthorised)
            }
            didSeed = true
        }
    }
}
#endif
