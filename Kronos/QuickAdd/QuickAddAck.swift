// Kronos/QuickAdd/QuickAddAck.swift
// The ONE acknowledgement of a quick add: the shell's undo pill, saying where the task went
// ("Added to Acme", "Added to Inbox", "Added for Tomorrow") and, once auto-triage has given it a
// first move, "· first move ready". No second notice inside the panel.
import Foundation
import KronosCore

@MainActor
enum QuickAddAck {
    /// How long the pill waits for auto-triage's first move before it stays as it is.
    static let firstMoveWait: Duration = .seconds(3)

    static func message(for task: KTask, store: TaskStore, firstMoveReady: Bool) -> String {
        let areaName = task.project == nil
            ? task.areaID.flatMap { id in store.allAreas().first { $0.id == id }?.name } : nil
        let destination = QuickAddPolicy.destination(projectName: task.project?.name, areaName: areaName,
                                                     isWaiting: task.status == .waiting, dueDay: task.dueDay)
        switch destination {
        case .project(let name), .area(let name):
            return to(name, firstMoveReady)
        case .waiting:
            return to(String(localized: "sidebar.waiting"), firstMoveReady)
        case .inbox:
            return to(String(localized: "sidebar.inbox"), firstMoveReady)
        case .day(let day):
            let when = EntryFormat.relativeDay(day)
            return String(format: String(localized: firstMoveReady ? "quickadd.ack.day.firstmove" : "quickadd.ack.day"), when)
        }
    }

    private static func to(_ name: String, _ firstMoveReady: Bool) -> String {
        String(format: String(localized: firstMoveReady ? "quickadd.ack.to.firstmove" : "quickadd.ack.to"), name)
    }

    private static func hasFirstMove(_ task: KTask) -> Bool {
        !(task.firstMove ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Posts the pill for `task`, then upgrades the same pill once a first move appears (only
    /// while that pill is still the one on screen).
    static func post(_ task: KTask, model: AppModel) {
        let id = task.id
        let ready = hasFirstMove(task)
        let first = message(for: task, store: model.store, firstMoveReady: ready)
        UndoToastCenter.shared.show(first)
        guard !ready else { return }
        Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: firstMoveWait)
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(150))
                guard UndoToastCenter.shared.current?.message == first else { return }
                guard let t = model.store.task(id) else { return }
                if hasFirstMove(t) {
                    UndoToastCenter.shared.show(message(for: t, store: model.store, firstMoveReady: true))
                    return
                }
            }
        }
    }
}
