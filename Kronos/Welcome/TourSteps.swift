// Kronos/Welcome/TourSteps.swift — the guided tour's steps and pure navigation rules (a guided
// tour of the app). After the welcome modal, Kronos walks
// through the real window: a bubble next to one part at a time, the rest dimmed, Next / Back /
// Skip. A step whose part is not on screen right now (Now card turned off, inspector folded,
// empty store) is skipped in the direction of travel instead of pointing at nothing.
// Foundation only: scripts/tour-selftest.swift compiles this file standalone.
import Foundation
import CoreGraphics

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

/// Where the bubble sits. Pure geometry so a hand table can prove "never covers the cards".
enum TourPlacement {
    /// The top-left corner of the bubble.
    ///
    /// `target` is the lit part (nil: the menu bar step has none). `avoid` are parts the bubble
    /// must not hide, the "Learn Kronos" and Now cards when they are not the target: the old rule
    /// only looked at the target and parked the bubble on top of the card the next step points
    /// at. Candidates are tried in reading order (beside a narrow or tall part, otherwise below,
    /// above, then the sides); the first one that touches neither the target nor an avoided part
    /// wins, else the one that hides the least. Always inside the window by `margin`.
    static func origin(target: CGRect?, avoid: [CGRect], in size: CGSize, bubble: CGSize,
                       margin inset: CGFloat, gap: CGFloat) -> CGPoint {
        // With no part to point at the bubble sits in a corner: twice the margin keeps its glow off
        // the window's corner pixels (the dimmed window must stay pure black there).
        let margin = target == nil ? inset * 2 : inset
        let maxX = max(margin, size.width - bubble.width - margin)
        let maxY = max(margin, size.height - bubble.height - margin)
        func clamped(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, margin), maxX), y: min(max(p.y, margin), maxY)) }

        // (point, axes that must fit in the window). The first candidate on each side keeps the old
        // behaviour (the other axis is clamped); the variants after it slide past an avoided part
        // and only count when they fit as they are.
        typealias Candidate = (point: CGPoint, fitsX: Bool, fitsY: Bool)
        var candidates: [Candidate] = []
        if let target {
            let narrow = target.width < size.width / 3 || target.height > size.height / 2
            let sideYs = [target.minY + margin] + avoid.map { $0.maxY + gap } + avoid.map { $0.minY - gap - bubble.height }
            let belowYs = [target.maxY + gap] + avoid.filter { $0.maxY > target.maxY }.map { $0.maxY + gap }
            let aboveYs = [target.minY - gap - bubble.height] + avoid.filter { $0.minY < target.minY }.map { $0.minY - gap - bubble.height }
            let rights: [Candidate] = sideYs.enumerated().map { (CGPoint(x: target.maxX + gap, y: $1), true, $0 > 0) }
            let lefts: [Candidate] = sideYs.enumerated().map { (CGPoint(x: target.minX - gap - bubble.width, y: $1), true, $0 > 0) }
            let belows: [Candidate] = belowYs.map { (CGPoint(x: target.minX, y: $0), false, true) }
            let aboves: [Candidate] = aboveYs.map { (CGPoint(x: target.minX, y: $0), false, true) }
            candidates = narrow ? rights + lefts + belows + aboves : belows + aboves + rights + lefts
        } else {
            candidates = [(CGPoint(x: maxX, y: margin), true, true), (CGPoint(x: maxX, y: maxY), true, true),
                          (CGPoint(x: margin, y: margin), true, true), (CGPoint(x: margin, y: maxY), true, true)]
        }
        let fitting = candidates.filter { c in
            (!c.fitsX || (c.point.x >= margin - 0.5 && c.point.x <= maxX + 0.5))
                && (!c.fitsY || (c.point.y >= margin - 0.5 && c.point.y <= maxY + 0.5))
        }
        let pool = (fitting.isEmpty ? candidates : fitting).map { clamped($0.point) }
        let hidden = (target.map { [$0.insetBy(dx: -gap / 2, dy: -gap / 2)] } ?? []) + avoid
        func cost(_ p: CGPoint) -> CGFloat {
            let frame = CGRect(origin: p, size: bubble)
            return hidden.reduce(0) { sum, r in
                let i = frame.intersection(r)
                return sum + (i.isNull ? 0 : i.width * i.height)
            }
        }
        var best = pool[0], bestCost = cost(pool[0])
        for p in pool.dropFirst() where bestCost > 0 {
            let c = cost(p)
            if c < bestCost { best = p; bestCost = c }
        }
        return best
    }
}

/// The sample task the tour makes on an empty store, and the keys of its text.
enum TourSample {
    /// Two tasks: the first is the one the Now card shows, the second gives the list its first row.
    static let titleKeys = ["welcome.tour.sample.title", "welcome.tour.sample2.title"]
    /// UserDefaults key (always `KronosEnv.defaults`) holding the sample's id while it exists, so
    /// an app quit in the middle of the tour cannot leave it behind.
    static let defaultsKey = "kronos.tour.sampleTaskID"
}
