// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols.
#if !RELEASE
// Kronos/QuickAdd/QuickAddSnapshots.swift
// Named screens for Kronos/Shared/SnapshotHarness.swift. `QuickAddSnapshots.screens(model:)`
// is wired into that file's registry array. Seeding happens in the returned view's
// `.onAppear`, never while this dictionary is built.
import SwiftUI
import AppKit
import KronosCore

/// Round-trips a `KProjectPalette` swatch back to `KProject.colorHex` for seeding — same
/// private helper `Kronos/Capture/CaptureSnapshots.swift` keeps its own copy of (see that
/// file's note on `Kronos/DesignSystem/ColorHexString.swift`), scoped here to snapshot fixtures.
private extension Color {
    var quickAddHexString: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((resolved.redComponent * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

@MainActor
enum QuickAddSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            // Empty field: legend collapsed, one example line as the placeholder (D8).
            "quickadd.panel": AnyView(QuickAddPanelView(model: model, seedLegendPinned: false, onSubmit: {}, onClose: {})),
            // "Show syntax" opened on an empty field: the full legend.
            "quickadd.panel.legend": AnyView(QuickAddPanelView(model: model, seedLegendPinned: true, onSubmit: {}, onClose: {})),
            // Restored draft: text present with the faint "Draft" caption (selection is AppKit-only).
            "quickadd.panel.draft": AnyView(QuickAddPanelView(
                model: model, seedText: "Call the accountant about Q3", seedIsDraft: true, seedLegendPinned: false,
                onSubmit: {}, onClose: {})),
            // Seeded text that hits every token kind at once (project, label, priority,
            // effort, date) so the parsed-chip row is fully exercised (G2/G3).
            "quickadd.panel.parsed": AnyView(SeededQuickAddPanel(model: model)),
            // "Show syntax" pressed while typing: the SAME full legend as the empty
            // state, not a one-line hint — proves every symbol incl. the `*` effort
            // alias is visible together with real typed text.
            "quickadd.panel.syntax": AnyView(QuickAddPanelView(
                model: model, seedText: "Send the Acme proposal", seedLegendPinned: true,
                onSubmit: {}, onClose: {})),
            // Subtasks: a task line followed by Tab-indented lines proves
            // the multi-line TextEditor renders real line breaks and the "N subtasks: …"
            // summary appears under the chips instead of the legend.
            "quickadd.panel.outline": AnyView(QuickAddPanelView(
                model: model, seedText: "Prepare the offer !! sutra\n\tfind the template\n\tfill in prices",
                onSubmit: {}, onClose: {})),
            // `>` at the start of a line is a subtask bullet too (TaskOutline.swift:52),
            // mixed with `-` in the same group — proves the render side of the fix; the parsing
            // side is proven by TaskOutlineTests.mixedDashAngleAndTabSubtasksInOneGroup.
            "quickadd.panel.outline.mixed": AnyView(QuickAddPanelView(
                model: model, seedText: "Prepare the offer\n- find the template\n> fill in prices",
                onSubmit: {}, onClose: {})),
            // The Waiting toggle (footer, filled when on).
            "quickadd.panel.waiting": AnyView(QuickAddPanelView(
                model: model, seedText: "Wait for Acme to reply", seedIsWaiting: true,
                onSubmit: {}, onClose: {})),
            // Entry field: `#hi` typed, the suggestion list open (projects, an area, the create row).
            "quickadd.entry.suggest": AnyView(SeededEntryPanel(model: model, text: "Call mom #hi")),
            // Entry field: every pill kind at once (destination, label, priority, effort, date).
            "quickadd.entry.pills": AnyView(SeededEntryPanel(model: model, text: "Call mom", pills: { m in
                [.destination(SeededEntryPanel.destination(m, "Hit list")), .label("finance"), .priority(.high),
                 .effort(.m), .due(Day.today(calendar: KronosLocale.calendar) + 1)] })),
            // Entry field: a long name and an area wrap onto a second line instead of overflowing.
            "quickadd.entry.pills.long": AnyView(SeededEntryPanel(model: model, text: "Prepare the offer", pills: { m in
                [.destination(SeededEntryPanel.destination(m, "Hit list")), .label("deep work and long review sessions"),
                 .priority(.urgent), .effort(.xl), .due(Day.today(calendar: KronosLocale.calendar) + 3)] })),
            // Entry field: a project created on submit and an unresolved #word offered as "Create project".
            "quickadd.entry.create": AnyView(SeededEntryPanel(model: model, text: "Plan the launch #brand-new")),
            // Entry field: a pill clicked open (its alternatives listed).
            "quickadd.entry.slotmenu": AnyView(SeededEntryPanel(model: model, text: "Call mom", pills: { m in
                [.destination(SeededEntryPanel.destination(m, "Hit list")), .priority(.medium)] }, openSlot: .destination)),
            // Entry field: a date word typed (the resolved date shown).
            "quickadd.entry.date": AnyView(SeededEntryPanel(model: model, text: "Pay the invoice next we")),
            // Entry field: a repeat phrase typed (the schedule shown as a pill).
            "quickadd.entry.repeat": AnyView(SeededEntryPanel(model: model, text: "Send the report every 2 weeks")),
            // First quick adds: the legend opens by itself; the placeholder shows its first example.
            "quickadd.panel.firstrun": AnyView(QuickAddPanelView(model: model, seedLegendPinned: false, seedAddsCount: 0,
                                                               seedGhost: 0, onSubmit: {}, onClose: {})),
            // The placeholder on a later example (the one that teaches repeats).
            "quickadd.panel.ghost": AnyView(QuickAddPanelView(model: model, seedLegendPinned: false, seedGhost: 4,
                                                            onSubmit: {}, onClose: {})),
            // Opened over a browser: the page title as the starting title, the page as a chip.
            "quickadd.panel.context": AnyView(QuickAddPanelView(
                model: model, seedText: "Quarterly report draft", seedLegendPinned: false,
                context: QuickAddContextState(links: [
                    ContextLink(kind: .web, reference: "https://example.com/reports/q3", displayName: "Quarterly report draft"),
                    ContextLink(kind: .email, reference: "message://%3Cq3@example.com%3E", displayName: "Re: Q3 numbers"),
                ]),
                onSubmit: {}, onClose: {})),
            // Opened over a browser whose Automation answer is not known yet: the chip that asks.
            "quickadd.panel.consent": AnyView(QuickAddPanelView(
                model: model, seedLegendPinned: false,
                context: QuickAddContextState(links: [], consent: .safari,
                                              front: QuickAddFrontApp(bundleID: "com.apple.Safari", pid: 0, name: "Safari")),
                seedGhost: 0, onSubmit: {}, onClose: {})),
        ]
    }
}

/// Seeds a matching project on `.onAppear` (never while the registry dictionary is built,
/// which would leak the seed into other screens) so `#acme` resolves to a real
/// `KProjectGlyph` rather than the unresolved-token chip, then hands the field a line that
/// carries one of every token: project, label, priority, effort, date.
private struct SeededQuickAddPanel: View {
    let model: AppModel
    @State private var didSeed = false

    var body: some View {
        Group {
            if didSeed {
                QuickAddPanelView(model: model, seedText: "Send the Acme proposal #acme @finance !!! ~m sutra",
                                  onSubmit: {}, onClose: {})
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard !didSeed else { return }
            _ = model.store.createProject(name: "Acme", colorHex: KProjectPalette.swatches[10].color.quickAddHexString,
                                          icon: "briefcase", area: nil)
            model.didMutate()
            didSeed = true
        }
    }
}

/// Seeds projects, an area and a label on `.onAppear` (never while the registry dictionary is
/// built), then shows the panel over an entry model that has the seeded catalog.
private struct SeededEntryPanel: View {
    let model: AppModel
    var text: String
    var pills: (AppModel) -> [EntryPill] = { _ in [] }
    var openSlot: EntryPill.Slot?
    @State private var entry: EntryFieldModel?

    static func destination(_ model: AppModel, _ name: String) -> EntryDestination {
        let p = model.store.allProjects().first { $0.name == name }
        return EntryDestination(kind: .project, name: name, id: p?.id)
    }

    var body: some View {
        Group {
            if let entry {
                QuickAddPanelView(model: model, seedLegendPinned: false, entry: entry, onSubmit: {}, onClose: {})
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard entry == nil else { return }
            let store = model.store
            if store.allProjects().first(where: { $0.name == "Hit list" }) == nil {
                _ = store.createProject(name: "Hit list", colorHex: KProjectPalette.swatches[10].color.quickAddHexString,
                                        icon: "target", area: nil)
                _ = store.createProject(name: "Hit parade", colorHex: KProjectPalette.swatches[4].color.quickAddHexString,
                                        icon: "flag", area: nil)
                _ = store.createProject(name: "Home renovation", colorHex: KProjectPalette.swatches[7].color.quickAddHexString,
                                        icon: "folder", area: nil)
                _ = store.createArea(name: "Hiring", colorHex: KProjectPalette.swatches[2].color.quickAddHexString)
                _ = store.label(named: "finance")
            }
            model.didMutate()
            let made = EntryFieldModel(text: text, pills: pills(model), catalog: EntryCatalog.make(store: store))
            if let slot = openSlot, let chip = made.resolved.chips.first(where: { $0.pill.slot == slot }) {
                made.openSlotMenu(chip)
            }
            entry = made
        }
    }
}
#endif
