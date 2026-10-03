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

private struct UITestAnchorReporter: View {
    let id: String
    let frame: CGRect
    @State private var token = UUID()
    var body: some View {
        Color.clear
            .onAppear { report(frame) }
            .onChange(of: frame) { _, new in report(new) }
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
            background(GeometryReader { geo in
                UITestAnchorReporter(id: id, frame: geo.frame(in: .global))
            })
        } else {
            self
        }
    }
}
