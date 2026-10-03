// Status, Labels and Waits on — the second tier of task metadata, on the borderless
// KPropertyRow property list (style G): one shared label column, quiet values, a
// full-row hover fill instead of a boxed control per field.
import SwiftUI
import KronosCore

struct InspectorStatusSection: View {
    let model: AppModel
    let task: KTask

    var body: some View {
        let _ = model.version  // blocked is derived from OTHER tasks: re-read after any store change
        VStack(alignment: .leading, spacing: 0) {
            KPropertyRow(String(localized: "detail.section.status")) {
                HStack(spacing: Space.x3) {
                    // The status itself as plain text; the chip beside it is a labelled
                    // toggle, so it can no longer be mistaken for the status (audit D1).
                    Text(statusValueText).font(Typo.row).foregroundStyle(Tok.textPrimary)
                        .uiTestAnchor("inspector.status.value")
                    statusMenu
                    if model.store.isBlocked(task.id) { blockedChip }
                }
            }
            .kInspectorFieldMenu(.status, task: task, model: model)
            labelsRow
            InspectorWaitsOnRow(model: model, task: task)
        }
    }

    /// One chip, not a "To do | Waiting" switch whose on side was ambiguous: a leading check and a
    /// quiet fill when the task IS waiting, a plain outline when it is not. On = `.waiting`; off =
    /// whatever the automatic rule says the due day implies (`.todo` with a due day,
    /// `.someday` without) — `TaskStore.setWaiting` computes that, so this never needs the rule.
    /// Other statuses (in progress, done) are reached through the checkbox and the palette.
    private var statusMenu: some View {
        let isWaiting = task.status == .waiting
        return InspectorToggleChip(title: String(localized: isWaiting ? "status.waiting" : "detail.status.markwaiting"),
                                   isOn: isWaiting, leadingIcon: "hourglass") {
            model.store.setWaiting(task.id, !isWaiting)
            model.didMutate()
        }
        .kTooltip(String(localized: "detail.help.waiting"))
        .uiTestAnchor("inspector.status.waiting")
    }

    /// The actual status in three plain words: Open (to do, in progress, someday), Done, Waiting.
    private var statusValueText: String {
        switch task.status {
        case .done: String(localized: "status.done")
        case .waiting: String(localized: "status.waiting")
        case .canceled: String(localized: "status.canceled")
        case .todo, .inProgress, .someday: String(localized: "detail.status.open")
        }
    }

    /// Derived by Core (a task it waits on is still open); not a status and not tappable, so it is
    /// a passive tag beside the Waiting chip, monochrome like everything else.
    private var blockedChip: some View {
        KTag(String(localized: "detail.blocked"), tone: Tok.textSecondary, font: Typo.meta)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "detail.blocked"))
    }

    // MARK: Labels

    private var labelsRow: some View {
        InspectorLabelsRow(model: model, task: task)
    }
}

private struct InspectorLabelsRow: View {
    let model: AppModel
    let task: KTask
    @State private var isAdding = false
    @State private var newLabelText = ""

    @State private var isAddHovering = false

    var body: some View {
        KPropertyRow(String(localized: "detail.section.labels")) {
            HStack(spacing: Space.x2) {
                if !labels.isEmpty {
                    InspectorFlowLayout(spacing: Space.x1) {
                        ForEach(labels, id: \.id) { label in
                            KChip(label.name, trailing: .clear, onTap: { remove(label) }) {
                                Circle().fill(Color(hexString: label.colorHex)).frame(width: Metrics.projectDot, height: Metrics.projectDot)
                            }
                            .kLabelContextMenu(label, task: task, model: model)
                        }
                    }
                }
                // `.kButton(.icon)` centres its glyph inside a Metrics.controlCompact
                // hit box, which put the "+" ink 8pt right of every other row's value x
                // when this is the first/only value. Built directly here so the glyph's
                // own ink can sit at x=0 of the value slot while keeping a full
                // Metrics.minHit tap target via contentShape, not the visible frame.
                // Root cause of a "must click 2-3 times" bug found in live UI testing:
                // a `.buttonStyle(.plain)` Button is only pressable on its label's
                // OPAQUE pixels — frame + contentShape must be INSIDE the label closure,
                // not chained after `.buttonStyle(.plain)`, or the click lands on a dead
                // wrapper outside the actual button.
                Button {
                    isAdding = true
                } label: {
                    Icon("plus", size: Metrics.iconS)
                        .foregroundStyle(isAddHovering ? Tok.textPrimary : Tok.textTertiary)
                        .frame(width: Metrics.minHit, height: Metrics.minHit, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isAddHovering = $0 }
                .animation(Motion.hover, value: isAddHovering)
                .accessibilityLabel(String(localized: "detail.labels.add"))
                .popover(isPresented: $isAdding) {
                    HStack(spacing: Space.x2) {
                        KTextField(String(localized: "detail.labels.add"), text: $newLabelText)
                            .frame(width: 180)
                            .onSubmit(addLabel)
                        Button(String(localized: "common.add"), action: addLabel)
                            .kButton(.secondary, size: .compact)
                    }
                    .padding(Space.x3)
                    .background(Tok.overlay)
                }
            }
        }
    }

    private var labels: [KLabel] { task.labels ?? [] }

    private func addLabel() {
        let trimmed = newLabelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let label = model.store.label(named: trimmed)
        model.store.addLabel(label, to: task.id)
        model.didMutate()
        newLabelText = ""
        isAdding = false
    }

    private func remove(_ label: KLabel) {
        model.store.removeLabel(label, from: task.id)
        model.didMutate()
    }
}

/// Minimal wrapping row layout for label chips — SwiftUI has no built-in flow layout.
struct InspectorFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Depth (attention demand) and Estimate (predicted duration) — quiet secondary
/// properties on the same borderless property list as Status/Project/Labels/Repeat,
/// NOT part of the three first-class attributes (effort/deadline/priority) at the top
/// of the pane, which stay on their own row. Both drive the ADHD ranking engine and
/// neither is emotional weight or a first-class attribute — effort covers the user's
/// own coarse sizing.
struct InspectorDepthEstimateSection: View {
    let model: AppModel
    let task: KTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KPropertyRow(String(localized: "detail.depth")) { depthMenu }
                .kInspectorFieldMenu(.depth, task: task, model: model)
                .kTooltip(String(localized: "detail.help.depth"))
            KPropertyRow(String(localized: "detail.estimate.short")) {
                EstimateField(model: model, task: task)
            }
            .kInspectorFieldMenu(.estimate, task: task, model: model)
            .kTooltip(String(localized: "detail.help.estimate"))
        }
    }

    private var depthMenu: some View {
        InspectorValueMenu(text: task.depth.displayName, isUnset: task.depth == .unknown) {
            ForEach(KDepth.allCases) { option in
                Button {
                    model.store.setDepth(task.id, option)
                    model.didMutate()
                } label: {
                    if option == task.depth {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        }
    }
}

/// Compact numeric field for `estimateMinutes`. A plain TextField rather than a
/// SwiftUI `TextField(value:)` bound to Int?: that variant shows a raw parse-error
/// state with no way to express "empty" distinctly from "zero", which this field
/// needs (nil clears the estimate; setEstimate(_:minutes:) takes an optional).
struct EstimateField: View {
    let model: AppModel
    let task: KTask
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Space.x1) {
            // The plain TextField ignores a prompt colour on macOS, so the dim placeholder is a
            // Text underneath that also gives the field its width.
            // Empty reads "Not set" like the Depth row above it, never a bare unit ("min").
            Text(draft.isEmpty ? String(localized: "detail.estimate.notset") : draft)
                .font(Typo.row)
                .foregroundStyle(draft.isEmpty ? Tok.textSecondary : Color.clear)
                .overlay(alignment: .leading) {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Typo.row)
                        .foregroundStyle(Tok.textPrimary)
                        .focused($isFocused)
                }
                .onChange(of: draft) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue { draft = digitsOnly }
                }
                .onChange(of: isFocused) { old, new in
                    if old, !new { commit() }
                }
                .onSubmit { commit() }
            // The unit suffix only shows once a value is entered ("Not set min" reads wrong).
            if !draft.isEmpty {
                Text(String(localized: "detail.estimate.unit"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
        .onAppear { draft = task.estimateMinutes.map(String.init) ?? "" }
        .onChange(of: task.estimateMinutes) { _, newValue in
            if !isFocused { draft = newValue.map(String.init) ?? "" }
        }
    }

    private func commit() {
        let minutes = Int(draft)
        guard minutes != task.estimateMinutes else { return }
        model.store.setEstimate(task.id, minutes: minutes)
        model.didMutate()
    }
}

extension KDepth {
    var displayName: String {
        switch self {
        case .unknown: String(localized: "depth.unknown")
        case .shallow: String(localized: "depth.shallow")
        case .deep: String(localized: "depth.deep")
        }
    }
}

extension KDepth: @retroactive Identifiable {
    public var id: Int { rawValue }
}

extension KStatus {
    var displayName: String {
        switch self {
        case .todo: String(localized: "status.todo")
        case .inProgress: String(localized: "status.inprogress")
        case .waiting: String(localized: "status.waiting")
        case .someday: String(localized: "detail.someday")
        case .done: String(localized: "status.done")
        case .canceled: String(localized: "status.canceled")
        }
    }
}

/// The one "Details" disclosure at the end of the inspector: everything that is not the
/// task itself (status, project, labels, depth, estimate, repeat, time block, focus,
/// re-triage) lives inside so the default view is only what is next. Open/closed is
/// remembered by the caller in UserDefaults; every field is one click away.
struct InspectorDetailsDisclosure<Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Button {
                withAnimation(Motion.curve(Motion.fast)) { isOpen.toggle() }
            } label: {
                HStack(spacing: Space.x2) {
                    InspectorSectionCaption(String(localized: "detail.details"))
                    Spacer(minLength: Space.x2)
                    Icon(isOpen ? "chevron-down" : "chevron-right", size: Metrics.iconXS)
                        .foregroundStyle(Tok.textTertiary)
                }
                .frame(height: Metrics.minHit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "detail.details"))
            .accessibilityAddTraits(isOpen ? [.isSelected] : [])
            .uiTestAnchor("inspector.details.toggle")
            if isOpen { content() }
        }
    }
}
