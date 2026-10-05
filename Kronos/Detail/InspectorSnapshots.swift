// Compiled only outside Release, like DetailSnapshots.swift: named screens for the snapshot
// harness covering the inspector's empty state, a long wrapped title with the "From <agent>"
// line and the Avoiding-it chip, a long note, and the Waiting / Blocked chips. Builders never
// touch the store at construction; each host seeds its task in `.onAppear`.
#if !RELEASE
import SwiftUI
import KronosCore

enum InspectorSnapshots {
    @MainActor
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "inspector.empty": AnyView(InspectorSnapshotHost(model: model, kind: .emptyWithFocus)),
            "inspector.empty.none": AnyView(InspectorEmptyState(model: model, previewNoFocus: true)
                .background(Tok.bg)),
            "inspector.longtitle": AnyView(InspectorSnapshotHost(model: model, kind: .longTitleAgent)),
            "inspector.notes.long": AnyView(InspectorSnapshotHost(model: model, kind: .longNotes)),
            "inspector.status.chips": AnyView(InspectorSnapshotHost(model: model, kind: .waitingBlocked)),
            "inspector.project": AnyView(InspectorSnapshotHost(model: model, kind: .projectField)),
            "inspector.projectpicker": AnyView(InspectorSnapshotHost(model: model, kind: .projectPicker)),
            // The shipped Deadline popover view (InspectorDeadlinePopover), seeded with a task.
            "inspector.deadline": AnyView(DeadlinePopoverSnapshotHost(model: model)),
        ]
    }
}

private struct DeadlinePopoverSnapshotHost: View {
    let model: AppModel
    @State private var task: KTask?

    var body: some View {
        Group {
            if let task {
                InspectorDeadlinePopover(model: model, task: task)
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))   // popover edge, so the insets can be read
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Color.clear
            }
        }
        .background(Tok.bg)
        .onAppear {
            guard task == nil else { return }
            let created = model.store.create(title: "Send the onboarding pack", notes: "", project: nil,
                                             status: .todo, priority: .none, dueDay: Day.today() + 3)
            model.didMutate()
            task = created
        }
    }
}

private struct InspectorSnapshotHost: View {
    enum Kind { case emptyWithFocus, longTitleAgent, longNotes, waitingBlocked, projectField, projectPicker }

    let model: AppModel
    let kind: Kind
    @State private var seeded = false

    var body: some View {
        InspectorScreen(model: model, previewDetailsOpen: kind == .waitingBlocked,
                        previewProjectPicker: kind == .projectPicker ? "kod" : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tok.bg)
            .onAppear(perform: seed)
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        let store = model.store
        switch kind {
        case .emptyWithFocus:
            let task = store.create(title: "Draft the quarterly investor update", notes: "", project: nil,
                                    status: .todo, priority: .high, dueDay: nil)
            store.setFirstMove(task.id, "Open last quarter's update and list what changed")
            model.didMutate()
            model.pinnedFocusTaskID = task.id
            model.selectedTaskID = nil
        case .longTitleAgent:
            let task = store.create(title: "Reconcile the March and April invoices against the bank export, then send the corrected totals to the accountant before the end of the month",
                                    notes: "", project: nil, status: .todo, priority: .medium, dueDay: nil)
            store.update(task.id) { $0.source = "agent:codex" }
            store.setDread(task.id, true)
            model.didMutate()
            model.selectedTaskID = task.id
        case .longNotes:
            let notes = (1...12).map { "Line \($0): a note long enough to be worth reading in full without a second scroll bar." }.joined(separator: "\n")
            let task = store.create(title: "Plan the offsite", notes: notes, project: nil,
                                    status: .todo, priority: .none, dueDay: nil)
            model.didMutate()
            model.selectedTaskID = task.id
        case .projectField, .projectPicker:
            let area = store.createArea(name: "Studio")
            let launch = store.createProject(name: "Kodiak Launch", colorHex: KProjectPalette.swatches[10].color.hexString, icon: "rocket", area: area)
            store.createProject(name: "Kitchen Remodel", colorHex: KProjectPalette.swatches[3].color.hexString, icon: nil, area: nil)
            store.createProject(name: "Škola Kod", colorHex: KProjectPalette.swatches[6].color.hexString, icon: nil, area: area)
            let task = store.create(title: "Plan the launch event", notes: "", project: launch,
                                    status: .todo, priority: .medium, dueDay: nil)
            model.didMutate()
            model.selectedTaskID = task.id
        case .waitingBlocked:
            let blocker = store.create(title: "Get the signed contract", notes: "", project: nil,
                                       status: .todo, priority: .none, dueDay: nil)
            let task = store.create(title: "Send the onboarding pack", notes: "", project: nil,
                                    status: .waiting, priority: .none, dueDay: nil)
            _ = store.setWaitsOn(task.id, [blocker.id])
            model.didMutate()
            model.selectedTaskID = task.id
        }
    }
}
#endif
