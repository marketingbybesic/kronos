// Kronos/Shared/LeftOffLine.swift
// ONE muted "where I left off" line: the next open step, else the first useful line of the notes.
// Shared by the Now card and the Impuls card; the menu-bar popover adopts the same view. The text
// decision lives in Kronos/Impuls/LeftOffText.swift (Foundation only, self-tested).
import SwiftUI
import KronosCore

struct LeftOffLine: View {
    let text: String

    var body: some View {
        Text(String(format: String(localized: "leftoff.line"), text))
            .font(Typo.meta)
            .foregroundStyle(Tok.textTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    /// The line for `task`, or nil when there is nothing to say beyond what the card already shows.
    @MainActor
    static func text(for task: KTask, hero: String) -> String? {
        LeftOffText.pick(nextStep: task.nextOpenSubtask?.title, notes: task.notes, hero: hero, title: task.title)
    }
}
