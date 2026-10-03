// Kronos/Shared/ProjectPicker.swift
// One type-ahead project picker: a field and the ranked projects under it. The inspector's Project
// field hosts it inline; the P key, the palette's "Move to" and the entry field adopt the same view
// and the same ranking (`ProjectRanking`: match tier first, recents first for an empty query).
//
// Keys (while the field has focus): Up/Down move the highlight, Return picks it, Esc closes without
// a change. SwiftUI's `.onKeyPress` does not fire while a TextField owns the field editor, so a
// local key monitor scoped to this view's lifetime reads them, and only while its own field is
// focused (a click into another field leaves them alone).
import SwiftUI
import AppKit
import KronosCore

struct ProjectPicker: View {
    let model: AppModel
    /// The task's current project: checkmarked, and what an equal pick leaves alone.
    var currentProjectID: UUID?
    /// Offers a "No project" row first while the field is empty.
    var allowsNone: Bool = true
    /// A project, or nil for "No project".
    var onPick: (KProject?) -> Void
    var onCancel: () -> Void
    /// Text typed before the person types anything (a caller that opens the picker from a key).
    var initialQuery: String = ""

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    /// Rows shown before the list scrolls.
    static let visibleRows = 8

    enum Row: Identifiable, Equatable {
        case none
        case project(ProjectRanking.Candidate)

        var id: String {
            switch self {
            case .none: "none"
            case .project(let c): c.id.uuidString
            }
        }
    }

    var body: some View {
        let _ = model.version
        VStack(alignment: .leading, spacing: Space.x2) {
            field
            if rows.isEmpty {
                Text(String(localized: "projectpicker.empty"))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.controlCompact, alignment: .leading)
                    .padding(.horizontal, Space.x2)
                    .uiTestAnchor("projectpicker.empty")
            } else {
                ScrollView {
                    VStack(spacing: Space.x1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowButton(row, index: index)
                        }
                    }
                }
                .frame(maxHeight: CGFloat(Self.visibleRows) * (Metrics.rowHeight + Space.x1))
            }
        }
        .background(KeyCatcher(onKey: handle))
        .onChange(of: query) { _, _ in highlighted = 0 }
        .uiTestAnchor("projectpicker")
    }

    // MARK: Data

    private var projects: [KProject] { model.store.allProjects() }

    private var recents: [UUID: Date] {
        let table = EntryRecents()
        return Dictionary(uniqueKeysWithValues: projects.compactMap { p in
            table.lastUsed(.project(p.id)).map { (p.id, $0) }
        })
    }

    private var rows: [Row] {
        let ranked = ProjectRanking.rank(query: query, projects: projects, recents: recents).map(Row.project)
        let showsNone = allowsNone && query.trimmingCharacters(in: .whitespaces).isEmpty
        return (showsNone ? [Row.none] : []) + ranked
    }

    // MARK: Field and rows

    private var field: some View {
        HStack(spacing: Space.x2) {
            Icon("search", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            TextField(String(localized: "projectpicker.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Tok.textPrimary)
                .focused($fieldFocused)
                .accessibilityLabel(String(localized: "projectpicker.placeholder"))
                .uiTestAnchor("projectpicker.field")
        }
        .padding(.horizontal, Space.x3)
        .frame(height: Metrics.controlRegular)
        .background(fieldFocused ? Tok.bg : Tok.controlFill)
        .kBorder(fieldFocused ? Tok.borderActive : Color.clear, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .onAppear {
            // One hop later: the field is not in the responder chain in the pass it appears in.
            if query.isEmpty { query = initialQuery }
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func rowButton(_ row: Row, index: Int) -> some View {
        let isHighlighted = index == highlighted
        let isCurrent = isCurrent(row)
        return Button { pick(row) } label: {
            HStack(spacing: Space.x2) {
                glyph(for: row)
                Text(title(of: row))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(1)
                if case .project(let c) = row, let area = c.areaName {
                    Text(area)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.x2)
                if isCurrent {
                    Icon("check", size: Metrics.iconS).foregroundStyle(Tok.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Space.x2)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(isHighlighted ? Tok.selectedFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(of: row))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .uiTestAnchor("projectpicker.row." + title(of: row))
    }

    @ViewBuilder
    private func glyph(for row: Row) -> some View {
        switch row {
        case .none:
            Icon("minus", size: Metrics.iconM)
                .foregroundStyle(Tok.textTertiary)
                .frame(width: Metrics.iconM, height: Metrics.iconM)
        case .project(let c):
            if let project = projects.first(where: { $0.id == c.id }) {
                KProjectGlyph(icon: project.icon, colorHex: project.colorHex, size: Metrics.iconM, carrier: .other)
            }
        }
    }

    private func title(of row: Row) -> String {
        switch row {
        case .none: String(localized: "detail.noproject")
        case .project(let c): c.name
        }
    }

    private func isCurrent(_ row: Row) -> Bool {
        switch row {
        case .none: currentProjectID == nil
        case .project(let c): c.id == currentProjectID
        }
    }

    // MARK: Picking and keys

    private func pick(_ row: Row) {
        switch row {
        case .none:
            onPick(nil)
        case .project(let c):
            guard let project = projects.first(where: { $0.id == c.id }) else { return }
            EntryRecents().record([.project(project.id)])
            onPick(project)
        }
    }

    /// True when the event was the picker's: the field has focus and it is Up, Down, Return or Esc
    /// without a command, option or control modifier.
    private func handle(_ event: NSEvent) -> Bool {
        guard fieldFocused else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard mods.isEmpty || mods == .shift else { return false }
        let count = rows.count
        switch event.keyCode {
        case 125:  // down
            if count > 0 { highlighted = min(count - 1, highlighted + 1) }
            return true
        case 126:  // up
            highlighted = max(0, highlighted - 1)
            return true
        case 36, 76:  // return, keypad enter
            if rows.indices.contains(highlighted) { pick(rows[highlighted]) }
            return true
        case 53:  // escape
            onCancel()
            return true
        default:
            return false
        }
    }
}

/// A local NSEvent monitor for this view's lifetime. The closure is refreshed on every update so it
/// always reads the current query, highlight and focus.
private struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.onKey = onKey
        DispatchQueue.main.async {
            guard context.coordinator.monitor == nil else { return }
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
                (coordinator?.onKey(event) ?? false) ? nil : event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        var onKey: (NSEvent) -> Bool = { _ in false }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
