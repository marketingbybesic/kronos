// Kronos/List/ListViewReset.swift — the three ways a list's view options go back to the person's own order.
//
// * Clear all: every sort and filter removed in one step; the list is the order the person set by
//   dragging again (nothing was ever rewritten: a sort only changes what is drawn). One undo step:
//   the pill's Undo and Cmd-Z put the rules back.
// * Switch to manual order: what a drag in a sorted list offers instead of silently doing nothing;
//   filters stay.
// * The drag hint itself: raised by the drop engine when a task is dropped on a sorted list, shown
//   as a one-line bar under the rules bar until it is used, dismissed, or the list changes.
import SwiftUI
import KronosCore

@MainActor
enum ListViewReset {
    /// The project the open list belongs to when it is a saved view made inside one: its pin. Read off
    /// the stored view, so it holds even when the options on screen lost it.
    static func pin(model: AppModel, scope: ListScope) -> UUID? {
        guard case .savedView(let id) = scope else { return nil }
        return model.store.allSavedViews().first { $0.id == id }?.homeProjectID
    }

    /// `options` with the pin of `scope` (if it has one) in place.
    static func pinned(_ options: ViewOptions, model: AppModel, scope: ListScope) -> ViewOptions {
        pin(model: model, scope: scope).map(options.pinned(to:)) ?? options
    }

    /// Removes every sort and filter of `scope`, except the project a saved view belongs to. Nothing
    /// to remove: nothing happens and no pill is raised.
    static func clearAll(model: AppModel, scope: ListScope) {
        let before = model.options(for: scope)
        let pin = Self.pin(model: model, scope: scope)
        guard before.hasRulesToClear(keepingPin: pin) else { return }
        model.setOptions(before.cleared(keepingPin: pin), for: scope)
        UndoToastCenter.shared.show(String(localized: "list.pill.viewcleared"),
                                    customUndo: { [model] in model.setOptions(before, for: scope) })
    }

    /// Back to the manual order, filters kept; one undo step like Clear all.
    static func switchToManual(model: AppModel, scope: ListScope) {
        let before = model.options(for: scope)
        guard !before.isManualOrder else { return }
        model.setOptions(before.switchedToManual(), for: scope)
        UndoToastCenter.shared.show(String(localized: "list.pill.manualorder"),
                                    customUndo: { [model] in model.setOptions(before, for: scope) })
    }
}

/// "Dragging only reorders a list in manual order": raised when a task is dropped on a list that is
/// sorted, so the drop is never a silent no-op. One list at a time.
@MainActor
@Observable
final class ListSortDragHint {
    static let shared = ListSortDragHint()
    private(set) var scopeKey: String?
    private init() {}

    func raise(for scope: ListScope) {
        scopeKey = scope.storageKey
        AccessibilityNotification.Announcement(String(localized: "list.sortdrag.hint")).post()
    }

    func dismiss() { scopeKey = nil }

    func isShowing(for scope: ListScope) -> Bool { scopeKey == scope.storageKey }
}

/// The hint bar: one calm line and one quiet action, hairline border, never red.
struct ListSortDragHintBar: View {
    let model: AppModel
    let scope: ListScope

    var body: some View {
        HStack(spacing: Space.x3) {
            Icon("grip-vertical", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            Text(String(localized: "list.sortdrag.hint"))
                .font(Typo.row)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .uiTestAnchor("list.sorthint")
            Spacer(minLength: Space.x3)
            Button(String(localized: "list.sortdrag.switch")) {
                ListSortDragHint.shared.dismiss()
                ListViewReset.switchToManual(model: model, scope: scope)
            }
            .kButton(.secondary, size: .compact)
            .uiTestAnchor("list.sorthint.switch")
            Button { ListSortDragHint.shared.dismiss() } label: {
                Icon("x", size: Metrics.iconXS)
                    .foregroundStyle(Tok.textTertiary)
                    .frame(width: Metrics.minHit, height: Metrics.minHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "common.close"))
        }
        .padding(.horizontal, Space.x3)
        .frame(minHeight: Metrics.controlRegular)
        .kBorder(Tok.borderControl, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
