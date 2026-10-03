// Inspector's two on/off chips and the "From <agent>" line.
//  - InspectorToggleChip: one interactive KChip whose on state differs by a leading check AND a
//    quiet fill, so nobody has to guess which side is on (Waiting, Avoiding it).
//  - InspectorDreadToggle: the "Avoiding it" switch (`KTask.dread`), writes through the store, one undo step.
//  - InspectorSourceLine: "From Codex" for a task an agent wrote.
import SwiftUI
import KronosCore

struct InspectorToggleChip: View {
    let title: String
    let isOn: Bool
    let leadingIcon: String
    let action: () -> Void

    var body: some View {
        KChip(title, onTap: action) {
            Icon(isOn ? "check" : leadingIcon, size: Metrics.iconXS)
                .foregroundStyle(isOn ? Tok.textPrimary : Tok.textTertiary)
        }
        .background(isOn ? Tok.selectedFill : Color.clear, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .accessibilityValue(String(localized: isOn ? "detail.toggle.on" : "detail.toggle.off"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct InspectorDreadToggle: View {
    let model: AppModel
    let task: KTask

    var body: some View {
        InspectorToggleChip(title: String(localized: "detail.dread"), isOn: task.dread, leadingIcon: "heart") {
            model.store.setDread(task.id, !task.dread)
            model.didMutate()
        }
        .kTooltip(String(localized: "detail.help.dread"))
        .uiTestAnchor("inspector.dread")
    }
}

struct InspectorSourceLine: View {
    let task: KTask

    var body: some View {
        switch InspectorSourceLabel.kind(source: task.source, hasAgentID: task.agentID != nil) {
        case .none:
            EmptyView()
        case .generic:
            line(String(localized: "detail.source.agent"))
        case .agent(let name):
            line(String(format: String(localized: "detail.source.from"), name))
        }
    }

    private func line(_ text: String) -> some View {
        HStack(spacing: Space.x1) {
            Icon("plug", size: Metrics.iconXS)
                .accessibilityHidden(true)
            Text(text)
        }
        .font(Typo.meta)
        .foregroundStyle(Tok.textTertiary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .uiTestAnchor("inspector.source")
    }
}
