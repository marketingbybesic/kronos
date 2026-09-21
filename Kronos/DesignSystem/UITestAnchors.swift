// Frames for the live UI test (Kronos/App/LiveUITest.swift). SwiftUI builds no accessibility tree
// for in-process callers, so views that the test must click report their own window frame here.
// Outside a test run (`KRONOS_UITEST` unset) the modifier returns the view untouched.
import SwiftUI

@MainActor
enum UITestAnchors {
    static let isOn = ProcessInfo.processInfo.environment["KRONOS_UITEST"] != nil
    /// SwiftUI global space: window content coordinates, origin TOP-left.
    static var frames: [String: CGRect] = [:]
}

extension View {
    @ViewBuilder
    func uiTestAnchor(_ id: String) -> some View {
        if UITestAnchors.isOn {
            background(GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Color.clear
                    .onAppear { UITestAnchors.frames[id] = frame }
                    .onChange(of: frame) { _, new in UITestAnchors.frames[id] = new }
                    .onDisappear { UITestAnchors.frames[id] = nil }
            })
        } else {
            self
        }
    }
}
