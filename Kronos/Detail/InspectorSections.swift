// Status, Project and Labels — the second tier of task metadata, on the borderless
// KPropertyRow property list (style G): one shared label column, quiet values, a
// full-row hover fill instead of a boxed control per field.
import SwiftUI
import KronosCore

struct InspectorStatusSection: View {
    let model: AppModel
    let task: KTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KPropertyRow(String(localized: "detail.section.status")) { statusMenu }
            KPropertyRow(String(localized: "detail.section.project")) { projectMenu }
            labelsRow
        }
    }

    private var statusMenu: some View {
        // ViewThatFits drops the "Waiting" text label first at the inspector's 300pt
        // minimum (the switch itself is the control; the word is a nice-to-have that
        // wrapped onto its own line and truncated at that width, caught on the narrow
        // screenshot read) — same fallback pattern as attributesRow above.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.x3) {
                statusMenuButton
                waitingToggle(showsLabel: true)
            }
            HStack(spacing: Space.x3) {
                statusMenuButton
                waitingToggle(showsLabel: false)
            }
        }
    }

    /// Someday is never a manual pick — the store sets/clears it on its own from the due day
    /// (`TaskStore.applyAutomaticStatusRule`). The menu below is therefore every status EXCEPT
    /// `.someday`; picking `.done`/`.canceled` still exits automatic tracking as before.
    private static let manualStatuses: [KStatus] = KStatus.allCases.filter { $0 != .someday }

    private var statusMenuButton: some View {
        InspectorValueMenu(text: task.status.displayName) {
            ForEach(Self.manualStatuses, id: \.self) { s in
                Button {
                    model.store.setStatus(task.id, s)
                    model.didMutate()
                } label: {
                    if s == task.status {
                        Label(s.displayName, systemImage: "checkmark")
                    } else {
                        Text(s.displayName)
                    }
                }
            }
        }
    }

    /// On = `.waiting`. Off = whatever the automatic rule says the due day implies
    /// (`.todo` with a due day, `.someday` without) — `TaskStore.setWaiting` computes that,
    /// so this toggle never needs to know the rule itself.
    private func waitingToggle(showsLabel: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { task.status == .waiting },
            set: { isOn in
                model.store.setWaiting(task.id, isOn)
                model.didMutate()
            }
        )) {
            if showsLabel {
                Text(String(localized: "status.waiting")).font(Typo.row).foregroundStyle(Tok.textSecondary)
            }
        }
        .toggleStyle(.switch)
        .tint(Tok.textPrimary)
        .accessibilityLabel(String(localized: "status.waiting"))
        .fixedSize()
    }

    // MARK: Project

    private var projectMenu: some View {
        // The glyph is the row's leading content (its own column, like every other
        // icon+text row in the app) and its own ink starts on the shared value x; the
        // project NAME follows after it, not aligned to that x itself.
        InspectorValueMenu(text: task.project?.name ?? String(localized: "detail.noproject")) {
            if let project = task.project {
                // Same carrier as the list row (gate G3): this glyph shows the SAME task
                // identity as the row it was opened from, so "focus row glyph" off must also
                // mean off here — otherwise closing the row's colour just relocates it to the
                // inspector the moment that row is selected.
                KProjectGlyph(icon: project.icon, colorHex: project.colorHex,
                              isFocus: task.id == model.focusTaskID, size: Metrics.iconM, carrier: .rowGlyph)
            }
        } items: {
            Button(String(localized: "detail.noproject")) {
                model.store.move(task.id, toProject: nil)
                model.didMutate()
            }
            ForEach(projectsByArea, id: \.area) { group in
                Section(group.area) {
                    ForEach(group.projects, id: \.id) { project in
                        Button {
                            model.store.move(task.id, toProject: project)
                            model.didMutate()
                        } label: {
                            Text(project.name)
                        }
                    }
                }
            }
        }
    }

    private var projectsByArea: [(area: String, projects: [KProject])] {
        let all = model.store.allProjects()
        let grouped = Dictionary(grouping: all) { $0.area?.name ?? String(localized: "detail.noproject") }
        return grouped.keys.sorted().map { key in (area: key, projects: grouped[key] ?? []) }
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
                    FlowLayout(spacing: Space.x1) {
                        ForEach(labels, id: \.id) { label in
                            KChip(label.name, trailing: .clear, onTap: { remove(label) })
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
private struct FlowLayout: Layout {
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
            KPropertyRow(String(localized: "detail.estimate.short")) {
                EstimateField(model: model, task: task)
            }
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
            Text(draft.isEmpty ? String(localized: "detail.estimate.placeholder") : draft)
                .font(Typo.row)
                .foregroundStyle(draft.isEmpty ? Tok.textTertiary : Color.clear)
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
            // The unit suffix only shows once a value is entered: the placeholder
            // itself already reads "min" when empty, and pairing it with a trailing
            // "min" label doubled the word (caught on the screenshot read).
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
