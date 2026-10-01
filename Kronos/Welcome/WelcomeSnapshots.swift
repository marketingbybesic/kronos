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
        // Wave 19 "Start here": the intro, and the card on the real list in four states.
        screens["onboarding.intro"] = AnyView(OnboardingIntroView().fixedSize())
        let t0 = Date(timeIntervalSinceNow: -600)
        let basics = Quest.basics
        screens["onboarding.card.start"] = card(model, OnboardingState(startedAt: t0))
        screens["onboarding.card.mid"] = card(model, OnboardingState(startedAt: t0, done: [.capture, .finish]), justDone: .finish)
        screens["onboarding.card.expanded"] = card(model, OnboardingState(startedAt: t0, done: [.capture, .firstStep]), expanded: true)
        screens["onboarding.card.power"] = card(model, OnboardingState(startedAt: t0, done: basics + [.palette]))
        screens["onboarding.card.all"] = card(model, OnboardingState(startedAt: t0, done: [.capture, .seeNext, .impuls]), expanded: true)
        // Wave 21 guided tour over the real shell, one screen per interesting step.
        for (name, index) in [("lists", 0), ("add", 1), ("now", 2), ("inspector", 4), ("stuck", 5),
                              ("menubar", 6), ("learn", 7)] {
            screens["tour.\(name)"] = AnyView(AppShellView(model: model).onAppear {
                OnboardingCenter.shared.setFixture(OnboardingState(startedAt: t0, done: [.capture]))
                TourCenter.shared.setFixture(index: index)
            })
        }
        return screens
    }

    private static func card(_ model: AppModel, _ state: OnboardingState, justDone: Quest? = nil,
                             expanded: Bool = false) -> AnyView {
        // The list mounts its own card; the expanded state is shown as the card alone (its
        // "all steps" toggle is private state the list's copy cannot be told about).
        AnyView(Group {
            if expanded {
                OnboardingCard(model: model, startExpanded: true)
                    .padding(Space.x4)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                TaskListScreen(model: model)
            }
        }
        .background(Tok.bg)
        .onAppear { OnboardingCenter.shared.setFixture(state, justDone: justDone) })
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
