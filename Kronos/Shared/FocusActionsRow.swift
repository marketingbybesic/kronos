// Kronos/Shared/FocusActionsRow.swift
// Start / Not now / Tomorrow for THE focus task: one row, three plain verbs, the same words wherever
// the focus task is shown (Now card, menu-bar popover). The row only reports the tap; each host
// decides what the tap does to its own state. Start disappears once the task is started and pinned,
// so there is never a dead control.
import SwiftUI

struct FocusActionsRow: View {
    /// False once the task is in progress and pinned: there is nothing left to start.
    var showsStart: Bool
    let onStart: () -> Void
    let onNotNow: () -> Void
    let onTomorrow: () -> Void

    var body: some View {
        HStack(spacing: Space.x2) {
            if showsStart {
                Button(String(localized: "impuls.button.start"), action: onStart)
                    .kButton(.secondary, size: .compact)
                    .uiTestAnchor("focus.start")
            }
            Button(String(localized: "menubar.now.notnow"), action: onNotNow)
                .kButton(.ghost, size: .compact)
                .uiTestAnchor("focus.notnow")
            Button(String(localized: "menubar.now.snooze"), action: onTomorrow)
                .kButton(.ghost, size: .compact)
                .uiTestAnchor("focus.tomorrow")
            Spacer(minLength: 0)
        }
    }
}
