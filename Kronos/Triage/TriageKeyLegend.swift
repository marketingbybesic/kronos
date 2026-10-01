// Kronos/Triage/TriageKeyLegend.swift
//
// The Triage card's key legend. By default only the two keys that matter (⏎ accept, ⇥ skip);
// the field keys (1-4, S M L, T W N, D, P) and ⎋ appear while ⌥ is held or the pointer is over
// the legend. A 14-cap cheat sheet beside every card read as homework. Key handling is
// untouched (TriageFlowView.handleKey); this is display only.
import SwiftUI
import AppKit

struct TriageKeyLegend: View {
    typealias Hint = (keys: [String], label: String)
    let fieldHints: [Hint]
    let flowHints: [Hint]      // accept, skip, close in that order

    @State private var hovering = false
    @State private var optionHeld = false
    @State private var monitor: Any?

    private var revealed: Bool { hovering || optionHeld }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            KKeyHintRow(revealed ? flowHints : Array(flowHints.prefix(2)))
            // Only laid out while revealed: a reserved invisible row left an empty band under
            // every card. The card grows by one row while ⌥ / hover lasts.
            if revealed {
                KKeyHintRow(fieldHints)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.curve(Motion.fast), value: revealed)
        .onAppear {
            // flagsChanged is not a keyDown, so TriageKeyCatcher never sees it.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let held = event.modifierFlags.contains(.option)
                DispatchQueue.main.async { optionHeld = held }
                return event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
