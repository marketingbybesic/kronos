#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    // One line per leaf between the markers: `("A-UNDO", aUndoSteps),`.
    // On merge keep every line (union, merge order).
    static let leafSteps: [(name: String, run: @MainActor (AppModel) async -> Void)] = [
        // GROUP-STEPS-BEGIN
        ("A-INSPECTOR", aInspectorSteps),
        ("A-BACKUP", aBackupSteps),
        ("A-UNDO", aUndoSteps),
        ("B2-MENUBAR", b2MenuBarSteps),
        ("B2-INSPECTOR", b2InspectorSteps),
        ("B1-RANK", b1RankSteps),
        ("A-AI", aAISteps),
        ("B2-IMPULS", b2ImpulsSteps),
        ("B2-TRIAGE", b2TriageSteps),
        ("D-MACSYS", dMacSysSteps),
        ("B1-TODAY", b1TodaySteps),
        ("D-REVIEW", dReviewSteps),
        ("B1-AI", b1AISteps),
        ("B2-LIST", b2ListSteps),
        ("D-STORE", dropStep),
        ("C-PALETTE", cPaletteSteps),
        ("C-SIDEBAR", cSidebarSteps),
        ("D-MACSYS2", dMacSys2Steps),
        ("C-SETTINGS", cSettingsSteps),
        ("D-NOTIFY", dNotifySteps),
        ("C-LIST", cListSteps),
        ("C-CAPTURE", cCaptureSteps),
        ("C-TRIAGE", cTriageSteps),
        ("E-POLISH", ePolishSteps),
        ("C-ONBOARD", cOnboardSteps),
        ("E-POLISH2", ePolish2Steps),
        ("E-A11Y", eA11ySteps),
        ("F-SORT", fSortSteps),
        ("F-OPEN", fOpenSteps),
        // GROUP-STEPS-END
    ]

    /// Runs every registered leaf step in order, or only the named one.
    static func runLeafSteps(_ model: AppModel, only: String? = nil) async {
        for step in leafSteps where only == nil || step.name == only {
            // A full run pushes far more than the 200-step undo cap; steps that count undo depth
            // must start below it.
            model.store.clearUndoHistory()
            await step.run(model)
        }
    }
}
#endif
