// Snapshot hosts for the "Waits on" row and its picker (w22e). Compiled only outside Release,
// like DetailSnapshots.swift. Everything is seeded in `.onAppear` (registry construction must
// not mutate the store) with fictional tasks only.
#if !RELEASE
import SwiftUI
import KronosCore

/// A blocked task (waits on two open tasks) in the REAL inspector with Details open: proves the
/// "Waits on" chips, the "+" and the "Blocked" chip beside Waiting.
struct WaitsOnSnapshotHost: View {
    let model: AppModel
    /// false = render the picker's popover content on its own (a presented popover is not capturable).
    var showPicker = false
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                if showPicker {
                    KPanel { InspectorWaitsOnRow(model: model, task: task).pickerContent }
                        .padding(Space.x4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    InspectorScreen(model: model, previewDetailsOpen: true)
                        .onAppear { model.selectedTaskID = task.id }
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            let a = model.store.create(title: "Get the pricing page approved")
            let b = model.store.create(title: "Send the contract to legal")
            _ = model.store.create(title: "Book the launch venue")
            _ = model.store.create(title: "Draft the press note")
            let blocked = model.store.create(title: "Publish the launch announcement")
            // The picker shows candidates minus what is already chosen; keep one chosen in the
            // picker variant too so the exclusion is visible.
            model.store.setWaitsOn(blocked.id, showPicker ? [a.id] : [a.id, b.id])
            model.didMutate()
            task = blocked
        }
    }
}

/// The quick add `/` list in a card, typed `/wee`, with fictional templates (the panel itself
/// cannot be hosted: it reads the shared TemplateStore, which the host fills in memory).
struct QuickAddTemplatesSnapshotHost: View {
    var typed = "/"
    private let sample = [
        TaskTemplate(name: "Weekly review", title: "Weekly review", subtasks: ["Clear the inbox"]),
        TaskTemplate(name: "Client kickoff", title: "Kick off the project"),
        TaskTemplate(name: "Invoice", title: "Send the invoice"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(typed).font(Typo.title).foregroundStyle(Tok.textPrimary)
            KHairline()
            QuickAddTemplateList(templates: sample, text: typed) { _ in }
        }
        .padding(Space.x5)
        .frame(width: 720)
        .background(Tok.overlay)
        .kBorder(Tok.borderControl, radius: Radius.popover)
        .padding(Space.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tok.bg)
    }
}

/// Settings > Data with a few templates, via the in-memory fixture list (never the real file).
struct TemplatesSnapshotHost: View {
    let model: AppModel
    var body: some View {
        SettingsScreen(model: model, initialTab: .data)
            .onAppear {
                TemplateStore.shared.setForSnapshot([
                    TaskTemplate(name: "Weekly review", title: "Weekly review",
                                 subtasks: ["Clear the inbox", "Plan next week"]),
                    TaskTemplate(name: "Client kickoff", title: "Kick off the project",
                                 subtasks: ["Send the agenda", "Book the call", "Share the brief"]),
                    TaskTemplate(name: "Invoice", title: "Send the invoice"),
                ])
            }
    }
}
#endif
