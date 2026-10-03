// Kronos/Detail/TooltipOverlay.swift
// A hover tooltip that can sit over a view that already carries its own `.help`. SwiftUI's `.help`
// on a container loses to an empty `.help("")` set deeper (the sidebar row sets one that is empty
// outside the icon rail), so the glosses this app adds to such rows are real AppKit tooltips on a
// transparent overlay that lets every click and key through. The text is the NSView's `toolTip`,
// which AppKit also exposes to VoiceOver as the element's help string.
import SwiftUI
import AppKit

private final class TooltipView: NSView {
    /// Never the target of a click, a drag or a key: the view underneath keeps all of them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

private struct TooltipOverlay: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = TooltipView()
        view.toolTip = text.isEmpty ? nil : text
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let wanted = text.isEmpty ? nil : text
        if view.toolTip != wanted { view.toolTip = wanted }
    }
}

extension View {
    /// Shows `text` as the hover tooltip over this view. An empty text shows none.
    func kTooltip(_ text: String) -> some View {
        overlay(TooltipOverlay(text: text))
    }
}

#if !RELEASE
extension NSView {
    /// Every tooltip string set anywhere under this view, for the live test.
    func collectToolTips() -> [String] {
        var found: [String] = []
        if let tip = toolTip, !tip.isEmpty { found.append(tip) }
        for sub in subviews { found.append(contentsOf: sub.collectToolTips()) }
        return found
    }
}
#endif
