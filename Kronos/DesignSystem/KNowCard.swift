// Kronos/DesignSystem/KNowCard.swift
// The focus task as a hero card: the FIRST MOVE is the hero line — the physical action that
// starts the task, not the task's name (activation, not planning) — with the title under it,
// one Complete control, the task's attributes, and how many are left. One hairline, no fill.
// Its project glyph is always `isFocus`, so in Focus mode this card is one of the few places
// hue appears; in Calm the glyph is neutral through `KProjectGlyph`'s own `carrier: .nowCard`
// tint (Chroma.tint always returns neutral for Calm), not by the card being absent — the
// owning screen (TaskListScreen.swift) used to also hide the WHOLE card under `!isCalm`, which
// made the card disappear rather than just desaturate; it now only gates on the Settings >
// Appearance "Now card" toggle.
// Usage:
//   KNowCard(firstMove: task.firstMove, title: task.title, remaining: 6,
//            projectIcon: "utensils", projectColorHex: "#F2994A", projectName: "Acme",
//            attributes: { KEffortIndicator(level: 3, label: "M"); KDeadlineLabel(text: "4d") },
//            onComplete: { complete() })
import SwiftUI

public struct KNowCard<Attributes: View>: View {
    let firstMove: String?
    let title: String
    let remaining: Int
    var projectIcon: String?
    var projectColorHex: String?
    var projectName: String?
    @ViewBuilder let attributes: () -> Attributes
    let onComplete: () -> Void
    @State private var isCompleting = false
    @State private var checkTrim: CGFloat = 0
    @State private var isHoveringComplete = false
    @FocusState private var isCompleteFocused: Bool
    @Environment(\.kAccent) private var accent

    public init(firstMove: String?, title: String, remaining: Int,
                projectIcon: String? = nil, projectColorHex: String? = nil, projectName: String? = nil,
                @ViewBuilder attributes: @escaping () -> Attributes,
                onComplete: @escaping () -> Void) {
        self.firstMove = firstMove
        self.title = title
        self.remaining = remaining
        self.projectIcon = projectIcon
        self.projectColorHex = projectColorHex
        self.projectName = projectName
        self.attributes = attributes
        self.onComplete = onComplete
    }

    private var move: String? {
        guard let firstMove, !firstMove.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return firstMove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(move == nil
                 ? String(localized: "nowcard.now", defaultValue: "Now")
                 : String(localized: "detail.firstmove"))
                .font(Typo.caption)
                .tracking(Tracking.caption)
                .textCase(.uppercase)
                .foregroundStyle(Tok.textTertiary)
            Text(move ?? title)
                .font(Typo.hero)
                .tracking(Tracking.tight)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.x3)
            if move != nil {
                Text(title)
                    .font(Typo.lead)
                    .foregroundStyle(Tok.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.x2)
            }
            footer.padding(.top, Space.x5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.nowCardPadding)
        .background(Tok.bg)
        .kBorder(Tok.borderControl, radius: Radius.popover)
        .opacity(isCompleting ? 0.55 : 1)
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: Space.x4) {
            completeButton
            HStack(spacing: Space.x3) { attributes() }
                .fixedSize()
            if projectIcon != nil || projectColorHex != nil {
                HStack(spacing: Space.x1 + 2) {
                    KProjectGlyph(icon: projectIcon, colorHex: projectColorHex, isFocus: true, size: Metrics.iconM, carrier: .nowCard)
                    if let projectName {
                        Text(projectName).font(Typo.meta).foregroundStyle(Tok.textTertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: Space.x3)
            Text(String(localized: "nowcard.remaining", defaultValue: "\(remaining) remaining"))
                .font(Typo.count)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    private var completeButton: some View {
        Button(action: complete) {
            HStack(spacing: Space.x3) {
                ZStack {
                    Circle().fill(isCompleting ? accent : (isHoveringComplete ? Tok.hoverFill : Color.clear))
                    Circle().strokeBorder(isCompleting ? Color.clear : (isHoveringComplete ? Tok.textPrimary : Tok.textSecondary),
                                          lineWidth: Metrics.strokeQuiet)
                    CheckMark()
                        .trim(from: 0, to: isCompleting ? checkTrim : (isHoveringComplete ? 1 : 0))
                        .stroke(isCompleting ? Accent.onFill(accent) : Tok.textDisabled,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: Metrics.nowCardComplete * 0.4, height: Metrics.nowCardComplete * 0.4)
                }
                .frame(width: Metrics.nowCardComplete, height: Metrics.nowCardComplete)
                Text(String(localized: "bar.menu.complete"))
                    .font(Typo.rowStrong)
                    .foregroundStyle(isHoveringComplete ? Tok.textPrimary : Tok.textSecondary)
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
        .disabled(isCompleting)
    }

    /// The check draws in and the card dims, THEN the task leaves: completion is seen to
    /// land before the list moves under it. Reduce Motion: immediate.
    private func complete() {
        guard !Motion.reduceMotion else { onComplete(); return }
        checkTrim = 0
        withAnimation(Motion.complete) {
            isCompleting = true
            checkTrim = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.medium + 0.06) {
            onComplete()
            isCompleting = false
        }
    }
}

public extension KNowCard where Attributes == EmptyView {
    init(firstMove: String?, title: String, remaining: Int,
         projectIcon: String? = nil, projectColorHex: String? = nil, projectName: String? = nil,
         onComplete: @escaping () -> Void) {
        self.init(firstMove: firstMove, title: title, remaining: remaining, projectIcon: projectIcon,
                  projectColorHex: projectColorHex, projectName: projectName,
                  attributes: { EmptyView() }, onComplete: onComplete)
    }
}
