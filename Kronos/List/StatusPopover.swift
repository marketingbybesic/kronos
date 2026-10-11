// Kronos/List/StatusPopover.swift
// The 5-option status picker `StatusCircle` opens on ⌥-click/right-click (spec §5.2,
// ux-12): Todo · In progress · Waiting · Done · Canceled, current one checked. Shared by every
// full task row (list, inspector, time blocks) so status always offers the same five choices
// in the same order, with the same write path as the row's own context menu's Status submenu
// (TaskContextMenu.swift) — `waiting` goes through its own writer (it also plans the check-in
// day), everything else through `setStatus`.
import SwiftUI
import KronosCore

/// `KTaskStatus` (the design system's own, KronosCore-free status enum) for a real task's
/// status — collapses `.someday` to `.todo`, same as every other 5-state call site.
extension KTaskStatus {
    init(_ status: KStatus) {
        switch status {
        case .todo, .someday: self = .todo
        case .inProgress: self = .inProgress
        case .waiting: self = .waiting
        case .done: self = .done
        case .canceled: self = .canceled
        }
    }
}

struct StatusPopover: View {
    let current: KStatus
    let onPick: (KStatus) -> Void

    private static let options: [KStatus] = [.todo, .inProgress, .waiting, .done, .canceled]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            ForEach(Self.options, id: \.self) { status in
                Button { onPick(status) } label: {
                    HStack(spacing: Space.x2) {
                        StatusCircle(status: KTaskStatus(status), size: Metrics.iconM) {}
                            .allowsHitTesting(false)
                        Text(ViewOptionsMapper.statusName(status))
                        Spacer(minLength: Space.x4)
                        if status == current { Icon("check", size: Metrics.iconXS).accessibilityHidden(true) }
                    }
                    .frame(minHeight: Metrics.minHit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
            }
        }
        .padding(Space.x3)
        .background(Tok.overlay)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "viewoptions.field.status"))
    }
}

/// The write a status popover pick makes, shared by every call site so `waiting`'s special
/// writer and the undo pill wording never drift from `TaskContextMenu`'s own Status submenu.
@MainActor
enum StatusPick {
    static func apply(_ status: KStatus, to task: KTask, model: AppModel) {
        guard task.status != status else { return }
        // Waiting goes through its own writer: it also plans the check-in day.
        if status == .waiting { model.store.setWaiting(task.id, true) } else { model.store.setStatus(task.id, status) }
        model.commit(String(format: String(localized: "list.pill.status"),
                             ViewOptionsMapper.statusName(status), task.title))
    }
}
