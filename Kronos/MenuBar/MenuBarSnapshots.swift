// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols without touching any
// file this leaf does not own.
#if !RELEASE
// Kronos/MenuBar/MenuBarSnapshots.swift
// Named screens for the snapshot harness: the Ordo popover content (automatic focus,
// pinned focus, a block suggestion, and the capture field focused), the menu-bar label on
// black, and the quick-add panel (empty and parsed). Popovers and panels cannot be
// captured while presented, so each exposes its CONTENT view directly.

import SwiftUI
import KronosCore

@MainActor
enum MenuBarSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "menubar.popover": AnyView(popover(model: model)),
            "menubar.popover.pinned": AnyView(pinnedPopover(model: model)),
            "menubar.popover.empty": AnyView(emptyPopover()),
            "menubar.popover.block": AnyView(blockPopover(model: model)),
            "menubar.popover.capture": AnyView(capturePopover(model: model)),
            "menubar.label": AnyView(label(subtask: "Otvoriti predložak", task: "Poslati ponudu klijentu Acme prije podneva",
                                            mode: .subtaskThenTask, width: .medium)),
            "menubar.label.taskonly": AnyView(label(subtask: "Otvoriti predložak", task: "Poslati ponudu klijentu Acme prije podneva",
                                                     mode: .taskOnly, width: .medium)),
            "menubar.label.allclear": AnyView(label(subtask: nil, task: nil, mode: .subtaskThenTask, width: .medium, symbol: "checkmark.circle")),
            "menubar.label.compact": AnyView(label(subtask: "Otvoriti predložak", task: "Poslati ponudu klijentu Acme prije podneva",
                                                    mode: .subtaskThenTask, width: .compact)),
            "menubar.label.medium": AnyView(label(subtask: "Otvoriti predložak", task: "Poslati ponudu klijentu Acme prije podneva",
                                                   mode: .subtaskThenTask, width: .medium)),
            "menubar.label.wide": AnyView(label(subtask: "Otvoriti predložak", task: "Poslati ponudu klijentu Acme prije podneva",
                                                 mode: .subtaskThenTask, width: .wide)),
            "menubar.label.full": AnyView(label(subtask: "Otvoriti predložak", task: "Poslati ponudu klijentu Acme prije podneva",
                                                 mode: .subtaskThenTask, width: .full)),
            "quickadd.panel": AnyView(panel(model: model, seedText: "")),
            "quickadd.panel.parsed": AnyView(panel(model: model, seedText: "Nazvati Alexa sutra !!! ~m #acme")),
        ]
    }

    /// The automatic Ordo focus (no pin): seeds a neutral project + task with a first move
    /// so the popover's project glyph and name are exercised, not just the fixed seed data,
    /// and publishes it via `model.publishOrdoFocus` — in the real app that publish comes
    /// from `TaskListScreen`, which this isolated popover screen never renders. Also seeds
    /// three more open tasks so the NEXT section has rows to show.
    private static func popover(model: AppModel) -> some View {
        PopoverContent(model: model, previewBlockSuggestion: .some(nil))
            .onAppear {
                guard model.store.allProjects().first(where: { $0.name == "Acme" }) == nil else { return }
                let project = seedAcme(model)
                // `.project(id)` rather than `.all` — `.all` would also match every task in
                // the harness's own `seed/kronos-seed.json` (37 REAL tasks, gate-shots.mjs
                // sets KRONOS_SEED unconditionally), leaking real business content into the
                // NEXT section. Scoping to this fixture's own project keeps it neutral.
                model.scope = .project(project.id)
                let task = model.store.create(title: "Send the September invoice to Acme", notes: "",
                                               project: project, status: .todo, priority: .none, dueDay: nil)
                model.store.setFirstMove(task.id, "Open the invoice template and fill in the September total")
                for title in ["Chase the Acme PO number", "Draft the Acme renewal email", "Archive last quarter's Acme thread"] {
                    _ = model.store.create(title: title, notes: "", project: project, status: .todo, priority: .none, dueDay: nil)
                }
                model.didMutate()
                model.publishOrdoFocus(OrdoFocus(taskID: task.id, title: task.title, firstMove: task.firstMove,
                                                  listName: "All", remaining: 6))
            }
    }

    /// A pinned focus task: a different neutral project + task, pinned via
    /// `model.pinnedFocusTaskID` so the popover renders its "Pinned" state and Unpin action.
    /// Also publishes a non-zero `ordoFocus` (a second, unrelated task) so "remaining" reads
    /// like a real queue behind the pin rather than the harness's untouched zero.
    private static func pinnedPopover(model: AppModel) -> some View {
        PopoverContent(model: model, previewBlockSuggestion: .some(nil))
            .onAppear {
                guard model.pinnedFocusTaskID == nil else { return }
                let project = model.store.createProject(name: "Globex", colorHex: KProjectPalette.swatches[2].color.hexString, icon: "utensils", area: nil)
                model.scope = .project(project.id)   // see popover(model:)'s note on why not .all
                let task = model.store.create(title: "Prep the Globex kickoff deck", notes: "",
                                               project: project, status: .todo, priority: .none, dueDay: nil)
                model.store.setFirstMove(task.id, "Duplicate last quarter's deck and swap the numbers")
                model.pinnedFocusTaskID = task.id
                let queued = model.store.create(title: "Reconcile August expenses", notes: "",
                                                 project: project, status: .todo, priority: .none, dueDay: nil)
                model.didMutate()
                model.publishOrdoFocus(OrdoFocus(taskID: queued.id, title: queued.title, firstMove: nil,
                                                  listName: "All", remaining: 4))
            }
    }

    private static func emptyPopover() -> some View {
        KOrdoPopoverG(task: nil, isPinned: false, onComplete: {}, onUnpin: {})
            .padding(Space.x4)
            .frame(width: 380)
            .background(Tok.bg)
    }

    /// Same focus fixture as `popover(model:)`, plus a fixed `BlockSuggestion` passed
    /// through `PopoverContent.previewBlockSuggestion` — the real `model.coach` has no
    /// injection seam for a fixture calendar (see that property's doc comment), so this is
    /// the only way to exercise the block banner without touching the real EventKit
    /// calendar or risking an unexpected consent prompt.
    private static func blockPopover(model: AppModel) -> some View {
        PopoverContent(model: model, previewBlockSuggestion: .some(fixtureSuggestion(model: model)))
            .onAppear {
                guard model.store.allProjects().first(where: { $0.name == "Acme" }) == nil else { return }
                let project = seedAcme(model)
                model.scope = .project(project.id)   // see popover(model:)'s note on why not .all
                let task = model.store.create(title: "Send the September invoice to Acme", notes: "",
                                               project: project, status: .todo, priority: .none, dueDay: nil)
                model.store.setFirstMove(task.id, "Open the invoice template and fill in the September total")
                model.didMutate()
                model.publishOrdoFocus(OrdoFocus(taskID: task.id, title: task.title, firstMove: task.firstMove,
                                                  listName: "All", remaining: 6))
            }
    }

    /// A stable, neutral suggestion for a project named "Globex" ending an hour from now —
    /// the exact minute never matters for a snapshot (it is read once and never advances).
    private static func fixtureSuggestion(model: AppModel) -> BlockSuggestion {
        let project = model.store.allProjects().first { $0.name == "Globex" }
            ?? model.store.createProject(name: "Globex", colorHex: KProjectPalette.swatches[2].color.hexString, icon: "utensils", area: nil)
        return BlockSuggestion(eventID: "fixture-standup", projectID: project.id, projectName: project.name,
                                endsAt: Date().addingTimeInterval(3600), kind: .starting)
    }

    /// The capture field focused on appear, so the snapshot shows its active border state.
    private static func capturePopover(model: AppModel) -> some View {
        PopoverContent(model: model, focusCaptureOnAppear: true, previewBlockSuggestion: .some(nil))
            .onAppear {
                guard model.store.allProjects().first(where: { $0.name == "Acme" }) == nil else { return }
                let project = seedAcme(model)
                model.scope = .project(project.id)   // see popover(model:)'s note on why not .all
                let task = model.store.create(title: "Send the September invoice to Acme", notes: "",
                                               project: project, status: .todo, priority: .none, dueDay: nil)
                model.didMutate()
                model.publishOrdoFocus(OrdoFocus(taskID: task.id, title: task.title, firstMove: task.firstMove,
                                                  listName: "All", remaining: 6))
            }
    }

    @discardableResult
    private static func seedAcme(_ model: AppModel) -> KProject {
        model.store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[6].color.hexString, icon: "briefcase", area: nil)
    }

    /// One rendered status-item label at a fixed width/mode/symbol combination: subtask
    /// then task, task only, all clear with check-circle, across four widths. `task: nil`
    /// renders the all-clear fallback title (`MenuBarStatusLabel`'s own nil branch), matching
    /// exactly what `MenuBarOrdoController.render()` shows for an empty queue. The UNTRUNCATED
    /// source strings are shown underneath in tertiary text so a manual review (verifying the
    /// parent truncates before the subtask) can check the composed title against its real
    /// source without guessing — also keeps this fixed-size chip from reading as a near-empty
    /// stub in a 700x260 canvas (gate-shots' own ink floor).
    private static func label(subtask: String?, task: String?, mode: MenuBarTitleMode, width: MenuBarWidth,
                               symbol: String = "circle") -> some View {
        // nil task = all-clear: MenuBarOrdoController.render() passes the literal
        // "menubar.allclear" title alongside the checkmark-circle symbol, never nil (nil
        // would fall back to MenuBarStatusLabel's own "ordo.title" placeholder instead).
        let title = task.map { MenuBarTitleComposer.compose(task: $0, subtask: subtask, mode: mode, width: width) }
            ?? String(localized: "menubar.allclear")
        let caption: String = {
            guard let task else { return "\(width.rawValue) · \(mode.rawValue): queue empty" }
            guard let subtask else { return "\(width.rawValue) · \(mode.rawValue): \(task)" }
            return "\(width.rawValue) · \(mode.rawValue): \(subtask) · \(task)"
        }()
        return VStack(alignment: .leading, spacing: Space.x3) {
            MenuBarStatusLabel(title: title, symbolName: symbol)
                .foregroundStyle(Tok.textPrimary)
                .frame(height: Metrics.controlCompact)
                .padding(.horizontal, Space.x2)
                .background(Tok.controlFill)
            KHairline()
            Text(caption)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    /// A project named "acme" so the `#acme` token in the parsed snapshot resolves. Seeded
    /// in `.onAppear`, not while this screens() dictionary is being built — the harness
    /// builds every registry before it picks one screen, so an eager write here would leak
    /// the Acme project into every other registered snapshot too.
    private static func panel(model: AppModel, seedText: String) -> some View {
        QuickAddPanelView(model: model, hotkeyNotice: nil, seedText: seedText, onSubmit: {}, onClose: {})
            .onAppear {
                if model.store.allProjects().first(where: { $0.name.lowercased() == "acme" }) == nil {
                    _ = model.store.createProject(name: "Acme")
                    model.didMutate()   // QuickAddPanelView observes model.version to re-render
                }
            }
    }
}
#endif
