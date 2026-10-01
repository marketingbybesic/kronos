// Kronos/Welcome/TourSteps.swift — the guided tour's steps and pure navigation rules (a guided
// tour of the app). After the welcome modal, Kronos walks
// through the real window: a bubble next to one part at a time, the rest dimmed, Next / Back /
// Skip. A step whose part is not on screen right now (Now card turned off, inspector folded,
// empty store) is skipped in the direction of travel instead of pointing at nothing.
// Foundation only: scripts/tour-selftest.swift compiles this file standalone.
import Foundation

/// A part of the window a step points at. Views mark themselves with `.tourAnchor(_:)`.
enum TourAnchor: String, CaseIterable, Hashable, Sendable {
    case sidebarLists, newTask, nowCard, firstRow, inspectorFirstMove, sidebarPower, learnCard
    /// Not a view: the bubble sits at the window's top-trailing corner, pointing up at the
    /// menu bar, so it is always "available".
    case menuBar
}

struct TourStep: Equatable, Sendable {
    enum Prepare: Equatable, Sendable {
        case none
        /// Select the first task of the open list so the inspector has something to show.
        case selectFirstTask
    }
    let anchor: TourAnchor
    let titleKey: String
    let bodyKey: String
    var hotkeyID: String? = nil
    var prepare: Prepare = .none
}

enum TourSteps {
    static let all: [TourStep] = [
        TourStep(anchor: .sidebarLists, titleKey: "welcome.tour.lists.title", bodyKey: "welcome.tour.lists.body"),
        TourStep(anchor: .newTask, titleKey: "welcome.tour.add.title", bodyKey: "welcome.tour.add.body",
                 hotkeyID: "global.quickadd"),
        TourStep(anchor: .nowCard, titleKey: "welcome.tour.now.title", bodyKey: "welcome.tour.now.body"),
        TourStep(anchor: .firstRow, titleKey: "welcome.tour.finish.title", bodyKey: "welcome.tour.finish.body"),
        TourStep(anchor: .inspectorFirstMove, titleKey: "welcome.tour.steps.title", bodyKey: "welcome.tour.steps.body",
                 prepare: .selectFirstTask),
        TourStep(anchor: .sidebarPower, titleKey: "welcome.tour.stuck.title", bodyKey: "welcome.tour.stuck.body"),
        TourStep(anchor: .menuBar, titleKey: "welcome.tour.menubar.title", bodyKey: "welcome.tour.menubar.body",
                 hotkeyID: "global.showordo"),
        TourStep(anchor: .learnCard, titleKey: "welcome.tour.learn.title", bodyKey: "welcome.tour.learn.body"),
    ]
}

enum TourLogic {
    /// The step to show when moving from `index` by `direction` (+1 / -1), skipping steps whose
    /// anchor is not on screen. nil = walked off the end (forward: the tour is over; backward:
    /// stay where you are, the caller keeps the current step).
    static func resolve(from index: Int, direction: Int, steps: [TourStep], available: Set<TourAnchor>) -> Int? {
        var i = index
        while true {
            i += direction
            guard steps.indices.contains(i) else { return nil }
            if isAvailable(steps[i].anchor, available) { return i }
        }
    }

    /// First step that can be shown at all (starting a tour), nil when none can.
    static func first(steps: [TourStep], available: Set<TourAnchor>) -> Int? {
        resolve(from: -1, direction: 1, steps: steps, available: available)
    }

    static func isAvailable(_ anchor: TourAnchor, _ available: Set<TourAnchor>) -> Bool {
        anchor == .menuBar || available.contains(anchor)
    }

    /// "3 / 7": position among the steps that are currently showable, so the counter never
    /// promises steps the tour will skip.
    static func progress(index: Int, steps: [TourStep], available: Set<TourAnchor>) -> (current: Int, total: Int) {
        let shown = steps.indices.filter { isAvailable(steps[$0].anchor, available) }
        let current = (shown.firstIndex(of: index) ?? 0) + 1
        return (current, shown.count)
    }
}
