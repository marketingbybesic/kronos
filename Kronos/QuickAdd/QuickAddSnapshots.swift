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
            // Empty field: shows the plain-word legend (G2).
            "quickadd.panel": AnyView(QuickAddPanelView(model: model, onSubmit: {}, onClose: {})),
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
#endif
