// Kronos/Welcome/OnboardingCard.swift — the "Start here" card at the top of the task list.
// One next quest, big, with ONE action ("Show me"); progress dots; the full list only on
// request. Pure #000 surface, hairline border, monochrome: the accent marks only the dots
// that are done. It refreshes on every store change, so a quest ticks the moment it happens.
import SwiftUI
import KronosCore

@MainActor
struct QuestCopy {
    let titleKey: String
    let howKey: String
    let hotkeyID: String?

    static func of(_ q: Quest) -> QuestCopy {
        switch q {
        case .capture: QuestCopy(titleKey: "welcome.quest.capture.title", howKey: "welcome.quest.capture.how", hotkeyID: "global.quickadd")
        case .firstStep: QuestCopy(titleKey: "welcome.quest.firststep.title", howKey: "welcome.quest.firststep.how", hotkeyID: nil)
        case .attach: QuestCopy(titleKey: "welcome.quest.attach.title", howKey: "welcome.quest.attach.how", hotkeyID: nil)
        case .seeNext: QuestCopy(titleKey: "welcome.quest.seenext.title", howKey: "welcome.quest.seenext.how", hotkeyID: "global.showordo")
        case .finish: QuestCopy(titleKey: "welcome.quest.finish.title", howKey: "welcome.quest.finish.how", hotkeyID: nil)
        case .triage: QuestCopy(titleKey: "welcome.quest.triage.title", howKey: "welcome.quest.triage.how", hotkeyID: "window.triage")
        case .impuls: QuestCopy(titleKey: "welcome.quest.impuls.title", howKey: "welcome.quest.impuls.how", hotkeyID: "window.impuls")
        case .captureNotes: QuestCopy(titleKey: "welcome.quest.capturenotes.title", howKey: "welcome.quest.capturenotes.how", hotkeyID: "window.capture")
        case .timeBlocks: QuestCopy(titleKey: "welcome.quest.timeblocks.title", howKey: "welcome.quest.timeblocks.how", hotkeyID: "window.timeblocks")
        case .palette: QuestCopy(titleKey: "welcome.quest.palette.title", howKey: "welcome.quest.palette.how", hotkeyID: "window.palette")
        }
    }

    var title: String { String(localized: String.LocalizationValue(titleKey)) }
    var how: String { String(localized: String.LocalizationValue(howKey)) }
    var keys: [String] { hotkeyID.flatMap { HotkeyRegistry.current(for: $0)?.displayKeys } ?? [] }
}

/// "Learn Kronos": every feature, tried when the user has time. Folded to one line by default
/// after the first look; the suggested next one is always visible. Every row works: its circle
/// marks it done, its title opens its explanation, "Try it" opens the real thing.
struct OnboardingCard: View {
    let model: AppModel
    var center = OnboardingCenter.shared
    @State private var showAll: Bool
    /// The row whose explanation + Try it are open; nil = the suggested next one.
    @State private var selected: Quest?

    /// `startExpanded` is for a snapshot fixture; the live card starts with the one next quest.
    init(model: AppModel, startExpanded: Bool = false) {
        self.model = model
        _showAll = State(initialValue: startExpanded)
    }

    private var active: Quest? {
        if let selected, !center.state.done.contains(selected) { return selected }
        return center.next
    }

    var body: some View {
        let _ = model.version
        Group {
            if center.isVisible, let active { card(active) }
        }
        // A sample task left by a tour that was cut short is removed as soon as the list mounts.
        .onAppear { TourCenter.shared.removeOrphanSample(model: model) }
    }

    @ViewBuilder
    private func card(_ active: Quest) -> some View {
        KPanel {
            VStack(alignment: .leading, spacing: Space.x3) {
                header
                if center.state.captureHintOpen, !center.state.collapsed { captureHint }
                if center.state.collapsed {
                    EmptyView()
                } else if showAll {
                    group("welcome.card.group.basics", Quest.basics, active: active)
                    group("welcome.card.group.power", Quest.power, active: active)
                } else {
                    row(active, isActive: true)
                }
            }
        }
        .onAppear { center.refresh(model) }
        .onChange(of: model.version) { _, _ in center.refresh(model) }
        .animation(Motion.curve(Motion.fast), value: center.state.done)
        .animation(Motion.curve(Motion.fast), value: showAll)
        .animation(Motion.curve(Motion.fast), value: selected)
        .uiTestAnchor("onboarding.card")
    }

    private var header: some View {
        HStack(spacing: Space.x2) {
            Text(String(localized: "welcome.card.title"))
                .font(Typo.sectionHdr)
                .foregroundStyle(Tok.textPrimary)
            if let just = center.justDone {
                Text(String(format: String(localized: "welcome.card.ticked"), QuestCopy.of(just).title))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: Space.x2)
            if !center.state.collapsed {
                Button(String(localized: showAll ? "welcome.card.fewer" : "welcome.card.all")) { showAll.toggle() }
                    .kButton(.ghost, size: .compact)
            }
            if OnboardingLogic.canDismiss(center.state) {
                Button(String(localized: "welcome.card.enough")) { center.dismiss() }
                    .kButton(.ghost, size: .compact)
                    .uiTestAnchor("onboarding.enough")
            }
            Button {
                center.setCollapsed(!center.state.collapsed)
            } label: {
                Icon(center.state.collapsed ? "chevron-down" : "chevron-up", size: Metrics.iconXS)
            }
            .kButton(.icon, size: .compact)
            .accessibilityLabel(String(localized: center.state.collapsed ? "welcome.card.expand" : "welcome.card.collapse"))
        }
    }

    /// Shown once, right after the first capture: where the fast way in lives.
    private var captureHint: some View {
        let keys = HotkeyRegistry.current(for: "global.quickadd")?.displayKeys ?? []
        return HStack(spacing: Space.x3) {
            Text(String(localized: "welcome.capturehint.text"))
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !keys.isEmpty { KKeyHintItem(keys, label: "") }
            Spacer(minLength: Space.x2)
            Button(String(localized: "welcome.capturehint.gotit")) { center.closeCaptureHint() }
                .kButton(.ghost, size: .compact)
                .uiTestAnchor("onboarding.capturehint.close")
        }
        .uiTestAnchor("onboarding.capturehint")
    }

    private func group(_ labelKey: String, _ quests: [Quest], active: Quest) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: String.LocalizationValue(labelKey)))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            ForEach(quests, id: \.self) { q in row(q, isActive: q == active) }
        }
    }

    private func row(_ q: Quest, isActive: Bool) -> some View {
        let copy = QuestCopy.of(q)
        let isDone = center.state.done.contains(q)
        return HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
            // The circle marks it done by hand (already did it another way, or knows it).
            Button { center.markDone(q) } label: {
                Icon(isDone ? "check" : "circle", size: Metrics.iconM)
                    .foregroundStyle(isDone ? Tok.textSecondary : (isActive ? Tok.textPrimary : Tok.textTertiary))
                    .frame(width: Metrics.minHit, height: Metrics.minHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDone)
            .help(String(localized: "welcome.card.markdone"))
            .accessibilityLabel(String(localized: "welcome.card.markdone"))
            VStack(alignment: .leading, spacing: Space.x1) {
                // The title opens this row's explanation and Try it.
                Button { selected = q } label: {
                    Text(copy.title)
                        .font(isActive ? Typo.heading : Typo.body)
                        .foregroundStyle(isDone ? Tok.textTertiary : Tok.textPrimary)
                        .strikethrough(isDone)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: Metrics.minHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDone)
                if isActive {
                    Text(copy.how)
                        .font(Typo.body)
                        .foregroundStyle(Tok.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !copy.keys.isEmpty {
                        KKeyHintItem(copy.keys, label: "")
                    }
                }
            }
            if !isDone {
                Button(String(localized: "welcome.showme")) { selected = q; center.showMe(q, model: model) }
                    .kButton(isActive ? .primary : .ghost, size: isActive ? .regular : .compact)
                    .uiTestAnchor("onboarding.showme")
            }
        }
    }
}
