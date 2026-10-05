// Frames for the live UI test (Kronos/App/LiveUITest.swift). SwiftUI builds no accessibility tree
// for in-process callers, so views that the test must click report their own window frame here.
// Outside a test run (`KRONOS_UITEST` unset) the modifier returns the view untouched.
import SwiftUI

@MainActor
enum UITestAnchors {
    static let isOn = ProcessInfo.processInfo.environment["KRONOS_UITEST"] != nil
    /// SwiftUI global space: window content coordinates, origin TOP-left.
    static var frames: [String: CGRect] = [:]
    /// Which view instance reported each id last. Two views can share an id when one replaces the
    /// other (the task inspector's Links section and the step inspector's); the outgoing view's
    /// onDisappear fires after the incoming one's onAppear and must not erase the new frame.
    static var owners: [String: UUID] = [:]
}

private struct UITestAnchorModifier: ViewModifier {
    let id: String
    @State private var token = UUID()
    // onGeometryChange re-reads the frame whenever the view MOVES in the window. A GeometryReader inside lazy
    // scroll content is not re-run when only content above the view changes size, so the frame stayed 40 pt
    // stale (a drag aimed at it landed on the wrong row) or never arrived (height 0).
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
            // The reader reports the first frame even when the change callback delivers none.
            .background(GeometryReader { geo in
                Color.clear.onAppear { if UITestAnchors.frames[id] == nil { report(geo.frame(in: .global)) } }
            })
            .onDisappear {
                guard UITestAnchors.owners[id] == token else { return }
                UITestAnchors.frames[id] = nil
                UITestAnchors.owners[id] = nil
            }
    }
    private func report(_ f: CGRect) {
        UITestAnchors.frames[id] = f
        UITestAnchors.owners[id] = token
    }
}

extension View {
    @ViewBuilder
    func uiTestAnchor(_ id: String) -> some View {
        if UITestAnchors.isOn {
            modifier(UITestAnchorModifier(id: id))
        } else {
            self
        }
    }
}
