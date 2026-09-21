// Kronos/MenuBar/KOrdoPopoverG.swift
// Style G content for the menu-bar Ordo popover's NOW section: FIRST MOVE label + first
// move as the hero line, title under it, the project's glyph + name, a quiet Complete
// control, "Not now" / Snooze, and the remaining count. A pin (Impuls Start / key F) shows
// an extra "Pinned" line and an Unpin action; completing a pinned task clears the pin
// (handled by the caller). Kept apart from `KNowCard` (the list pane's own hero card)
// because this one must fit a 380pt popover and needs the pinned-state affordance the Now
// card does not have. Next 5 / presets / energy / block / capture live in sibling files
// and are composed around this in `PopoverContent`.
import SwiftUI
import KronosCore

struct KOrdoPopoverG: View {
    let task: (id: UUID, title: String, firstMove: String?, remaining: Int, project: KProject?)?
    let isPinned: Bool
    let onComplete: () -> Void
    let onUnpin: () -> Void
    var onNotNow: (() -> Void)?
    var onSnooze: (() -> Void)?
    @State private var isHoveringComplete = false
    @FocusState private var isCompleteFocused: Bool
    @Environment(\.chromaMode) private var chromaMode

    private var move: String? {
        guard let firstMove = task?.firstMove, !firstMove.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return firstMove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let task {
                content(for: task)
            } else {
                KEmptyState(icon: "list-ordered", title: String(localized: "bar.empty"))
                    .padding(.vertical, Space.x5)
            }
        }
        // Padding + width are owned by the enclosing popover (`PopoverContent`, 380pt,
        // wide enough to fit Next 5 + presets + energy + block + capture as sibling
        // sections in the same padded column); this view only fills the space it is given.
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack {
            Text(String(localized: "ordo.title"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
                .fixedSize()
            if isPinned {
                Text(String(localized: "menubar.pinned.badge", defaultValue: "Pinned"))
                    .font(Typo.caption)
                    .tracking(Tracking.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize()
            }
            Spacer()
            if let task {
                Text(String(format: String(localized: "menubar.ordo.remaining"), "\(task.remaining)"))
                    .font(Typo.count)
                    .foregroundStyle(Tok.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func content(for task: (id: UUID, title: String, firstMove: String?, remaining: Int, project: KProject?)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(move == nil ? String(localized: "nowcard.now", defaultValue: "Now") : String(localized: "detail.firstmove"))
                .font(Typo.caption)
                .tracking(Tracking.caption)
                .textCase(.uppercase)
                .foregroundStyle(Tok.textTertiary)
                .padding(.top, Space.x4)
            Text(move ?? task.title)
                .font(Typo.hero)
                .tracking(Tracking.tight)
                .foregroundStyle(Tok.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.x2)
            if move != nil {
                Text(task.title)
                    .font(Typo.lead)
                    .foregroundStyle(Tok.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.x1)
            }
            footer(task).padding(.top, Space.x4)
            secondaryActions(task).padding(.top, Space.x2)
        }
    }

    private func footer(_ task: (id: UUID, title: String, firstMove: String?, remaining: Int, project: KProject?)) -> some View {
        HStack(spacing: Space.x3) {
            completeButton
            if let project = task.project {
                HStack(spacing: Space.x1 + 2) {
                    KProjectGlyph(icon: project.icon, colorHex: project.colorHex, isFocus: true, size: Metrics.iconM, carrier: .menuBarTitle)
                    Text(project.name)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.x2)
            if isPinned {
                Button(String(localized: "menubar.unpin", defaultValue: "Unpin"), action: onUnpin)
                    .buttonStyle(.plain)
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                    .fixedSize()
            }
        }
    }

    /// "Not now" (skip without completing, no shame copy) and Snooze to tomorrow — plan
    /// rev 9 feature J. Both are quiet text actions, same tone as Unpin above; neither
    /// implies failure, so neither is styled differently from an ordinary control.
    @ViewBuilder
    private func secondaryActions(_ task: (id: UUID, title: String, firstMove: String?, remaining: Int, project: KProject?)) -> some View {
        if onNotNow != nil || onSnooze != nil {
            HStack(spacing: Space.x4) {
                if let onNotNow {
                    Button(String(localized: "menubar.now.notnow"), action: onNotNow)
                        .buttonStyle(.plain)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .fixedSize()
                }
                if let onSnooze {
                    Button(String(localized: "menubar.now.snooze"), action: onSnooze)
                        .buttonStyle(.plain)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var completeButton: some View {
        Button(action: onComplete) {
            HStack(spacing: Space.x2) {
                Circle()
                    .strokeBorder(isHoveringComplete ? Tok.textPrimary : Tok.textSecondary, lineWidth: Metrics.strokeQuiet)
                    .background(Circle().fill(isHoveringComplete ? Tok.hoverFill : .clear))
                    .overlay(Icon("check", size: Metrics.iconS).foregroundStyle(isHoveringComplete ? Tok.textPrimary : Tok.textSecondary))
                    .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
                Text(String(localized: "bar.menu.complete"))
                    .font(Typo.rowStrong)
                    .foregroundStyle(isHoveringComplete ? Tok.textPrimary : Tok.textSecondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kFocusRing(isCompleteFocused, radius: Radius.full)
        .focusable(true, interactions: .activate)
        .focused($isCompleteFocused)
        .focusEffectDisabled()
        .onHover { isHoveringComplete = $0 }
        .animation(Motion.hover, value: isHoveringComplete)
        .accessibilityLabel(String(localized: "menubar.ordo.complete"))
        .accessibilityHint("Completes the next subtask, or the task")
    }
}
