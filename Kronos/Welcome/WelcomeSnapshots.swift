// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols.
#if !RELEASE
// Kronos/Welcome/WelcomeSnapshots.swift
// Extra named screens for Kronos/Shared/SnapshotHarness.swift: one per tour page, keyed
// `welcome.1`…`welcome.7`, each opened directly to its own page rather than the first — a
// gate never has to click "Next" six times to prove page 7 renders.
import SwiftUI

@MainActor
enum WelcomeSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        var screens: [String: AnyView] = [:]
        for page in WelcomePages.all {
            screens["welcome.\(page.id)"] = AnyView(preview(pageIndex: page.id - 1))
        }
        return screens
    }

    private static func preview(pageIndex: Int) -> some View {
        let welcomeModel = WelcomeModel()
        return WelcomeWindow(model: welcomeModel)
            .onAppear {
                while welcomeModel.index < pageIndex { welcomeModel.next() }
            }
            .fixedSize()
    }
}
#endif
