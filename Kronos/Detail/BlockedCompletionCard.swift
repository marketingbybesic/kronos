// Kronos/Detail/BlockedCompletionCard.swift
// "Finish <B> first": what happens when someone completes a task that still waits on open tasks.
// Every in-app completion path (list checkbox, Space, inspector, context menu, palette, Time Blocks,
// Triage, bulk) asks `AppModel.interceptBlockedCompletion` first. When the task has open blockers
// nothing is written; the shell shows this card with four ways out. `store.complete` itself stays
// unconditional (MCP, URL scheme, Intents, synced devices), so only the app's own UI asks.
//
//   Open <B>           select the blocker (closes Triage / Time Blocks so the selection is visible)
//   Complete both      blockers, then the task: ONE undo step (hidden while a blocker is itself blocked)
//   Remove dependency  drop the open blockers from the task and complete it: ONE undo step
//   Cancel             Esc; nothing changed
//
// Keys: Return = Open, B = Complete both, R = Remove dependency, Esc = Cancel. The card owns the
// keyboard while it is up (a local monitor swallows every other plain key), so the list, Triage
// and Time Blocks beneath the scrim cannot act on the same Space or Return a second time.
import SwiftUI
import AppKit
import KronosCore

/// A completion waiting for a decision. `finish` wraps the write the person chose together with
/// whatever the asking surface does after a completion (linger, selection, pill, next card).
struct BlockedCompletion {
    let taskID: UUID
    let blockerIDs: [UUID]
    let finish: @MainActor (_ write: () -> Void) -> Void
}

enum BlockedCompletionChoice { case open, completeBoth, removeDependency, cancel }

extension AppModel {
    /// Raises the card and returns true when `task` is open and waits on open tasks; the caller then
    /// writes nothing. Returns false when the completion may go ahead as it is.
    @discardableResult
    func interceptBlockedCompletion(of task: KTask, finish: @escaping @MainActor (_ write: () -> Void) -> Void) -> Bool {
        guard task.status != .done else { return false }
        let blockers = store.openBlockers(of: task.id)
        guard !blockers.isEmpty else { return false }
        pendingBlockedCompletion = BlockedCompletion(taskID: task.id, blockerIDs: blockers.map(\.id), finish: finish)
        return true
    }

    /// Carries out one of the card's choices. The store is re-read first: a blocker finished or a
    /// dependency removed meanwhile (another device, MCP) must not make a choice act on stale ids.
    func resolveBlockedCompletion(_ choice: BlockedCompletionChoice) {
        guard let pending = pendingBlockedCompletion else { return }
        let id = pending.taskID
        guard let task = store.task(id), task.status != .done else { pendingBlockedCompletion = nil; return }
        switch choice {
        case .cancel:
            pendingBlockedCompletion = nil
        case .open:
            pendingBlockedCompletion = nil
            guard let first = store.openBlockers(of: id).first?.id ?? pending.blockerIDs.first else { return }
            isTriageOpen = false
            isTimeBlocksOpen = false
            openDetails(taskID: first)
            NotificationCenter.default.post(name: UIRequests.focusList, object: nil)
        case .completeBoth:
            guard store.canCompleteWithBlockers(id) else { refreshBlockedCompletion(pending, task: task); return }
            pendingBlockedCompletion = nil
            let store = store
            pending.finish { store.completeWithBlockers(id) }
        case .removeDependency:
            pendingBlockedCompletion = nil
            let store = store
            pending.finish { store.completeRemovingBlockers(id) }
        }
    }

    /// The blockers changed under the card: show the new state, or just complete when none is left.
    private func refreshBlockedCompletion(_ pending: BlockedCompletion, task: KTask) {
        pendingBlockedCompletion = nil
        if !interceptBlockedCompletion(of: task, finish: pending.finish) {
            let store = store
            pending.finish { store.complete(task.id) }
        }
    }
}

struct BlockedCompletionCard: View {
    let model: AppModel
    let pending: BlockedCompletion
    @State private var keys = KeyMonitorBox()

    private var task: KTask? { model.store.task(pending.taskID) }
    private var blockers: [KTask] { pending.blockerIDs.compactMap { model.store.task($0) } }
    private var canCompleteBoth: Bool { model.store.canCompleteWithBlockers(pending.taskID) }

    var body: some View {
        let blockers = blockers
        VStack(alignment: .leading, spacing: Space.x3) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(title(blockers))
                    .font(Typo.heading)
                    .foregroundStyle(Tok.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle(blockers))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if blockers.count > 1 {
                VStack(alignment: .leading, spacing: Space.x1) {
                    ForEach(blockers, id: \.id) { b in
                        Text(b.waitsOnDisplayName)
                            .font(Typo.row)
                            .foregroundStyle(Tok.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(Space.x2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .kBorder(Tok.hairline, radius: Radius.row)
                .accessibilityElement(children: .combine)
            }
            VStack(spacing: Space.x2) {
                Button { model.resolveBlockedCompletion(.open) } label: {
                    Text(String(format: String(localized: "blocked.open"), blockers.first?.waitsOnDisplayName ?? ""))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
                }
                .kButton(.primary)
                .uiTestAnchor("blocked.open")
                if canCompleteBoth {
                    Button { model.resolveBlockedCompletion(.completeBoth) } label: {
                        Text(blockers.count > 1 ? String(localized: "blocked.all") : String(localized: "blocked.both"))
                            .frame(maxWidth: .infinity)
                    }
                    .kButton(.secondary)
                    .uiTestAnchor("blocked.both")
                }
                Button { model.resolveBlockedCompletion(.removeDependency) } label: {
                    Text(String(localized: "blocked.remove")).frame(maxWidth: .infinity)
                }
                .kButton(.secondary)
                .uiTestAnchor("blocked.remove")
                Button { model.resolveBlockedCompletion(.cancel) } label: {
                    Text(String(localized: "blocked.cancel")).frame(maxWidth: .infinity)
                }
                .kButton(.ghost)
                .uiTestAnchor("blocked.cancel")
            }
        }
        .padding(Space.x4)
        .frame(width: 360)
        .background(Tok.overlay)
        .kBorder(Tok.hairline, radius: Radius.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title(blockers))
        .uiTestAnchor("blocked.card")
        .onAppear { keys.install(model: model) }
        .onDisappear { keys.remove() }
    }

    private func title(_ blockers: [KTask]) -> String {
        guard blockers.count > 1 else {
            return String(format: String(localized: "blocked.title"), blockers.first?.waitsOnDisplayName ?? "")
        }
        return KPlural.hr(blockers.count, one: String(localized: "blocked.title.n.one"),
                          few: String(localized: "blocked.title.n.few"), many: String(localized: "blocked.title.n.many"))
    }

    private func subtitle(_ blockers: [KTask]) -> String {
        let name = task?.title ?? ""
        return String(format: blockers.count > 1 ? String(localized: "blocked.sub.many") : String(localized: "blocked.sub.one"), name)
    }
}

/// Owns the keyboard for as long as the card is up. Local monitors run newest first, so this one
/// sees a key before the Triage card's monitor and the list's key handling.
@MainActor
final class KeyMonitorBox {
    private var monitor: Any?

    func install(model: AppModel) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            let handled: Bool = MainActor.assumeIsolated {
                guard let model, model.pendingBlockedCompletion != nil else { return false }
                let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // Command chords (quit, close, undo) stay with the menu bar.
                if held.contains(.command) { return false }
                switch event.keyCode {
                case 53: model.resolveBlockedCompletion(.cancel)                  // Esc
                case 36, 76: model.resolveBlockedCompletion(.open)                // Return, keypad Enter
                default:
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "o": model.resolveBlockedCompletion(.open)
                    case "b": model.resolveBlockedCompletion(.completeBoth)
                    case "r": model.resolveBlockedCompletion(.removeDependency)
                    case "c": model.resolveBlockedCompletion(.cancel)
                    default: break
                    }
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
