// Kronos/DesignSystem/KIconPicker.swift
// Searchable grid of ProjectIconSet: 8 columns of 28 pt cells, grouped under quiet
// captions, monochrome (the chosen COLOUR is KColorSwatchPicker's job, next to it in the
// project editor). Keyboard: arrows move a cursor through the grid exactly as it is laid
// out (rows keep their column across group breaks), Return/Space picks, picking the
// selected icon again clears it (back to the plain dot). Type in the field to filter by
// icon name or group.
// Usage: KIconPicker(selection: $projectIcon)            // Binding<String?>
//        KIconPicker(selection: $icon, viewportHeight: nil)   // unbounded (gallery)
import SwiftUI

public struct KIconPicker: View {
    @Binding var selection: String?
    var viewportHeight: CGFloat?
    @State private var query = ""
    @State private var cursor: String?
    @FocusState private var isGridFocused: Bool

    public init(selection: Binding<String?>, viewportHeight: CGFloat? = Metrics.iconPickerViewport) {
        self._selection = selection
        self.viewportHeight = viewportHeight
    }

    /// Convenience for editors that hold the icon as a plain String ("" = none).
    public init(selection: Binding<String>, viewportHeight: CGFloat? = Metrics.iconPickerViewport) {
        self.init(selection: Binding<String?>(
            get: { selection.wrappedValue.isEmpty ? nil : selection.wrappedValue },
            set: { selection.wrappedValue = $0 ?? "" }), viewportHeight: viewportHeight)
    }

    private struct Section: Identifiable {
        let id: String
        let title: String?
        let rows: [[String]]
    }

    private static let width = CGFloat(Metrics.iconPickerColumns) * Metrics.iconPickerCell
        + CGFloat(Metrics.iconPickerColumns - 1) * Metrics.iconPickerGap

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var sections: [Section] {
        if isSearching {
            return [Section(id: "results", title: nil, rows: Self.chunk(ProjectIconSet.matching(query)))]
        }
        return ProjectIconSet.groups.map { Section(id: $0.id, title: $0.title, rows: Self.chunk($0.icons)) }
    }

    private static func chunk(_ icons: [String]) -> [[String]] {
        stride(from: 0, to: icons.count, by: Metrics.iconPickerColumns).map {
            Array(icons[$0..<min($0 + Metrics.iconPickerColumns, icons.count)])
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            KTextField(String(localized: "sidebar.search.placeholder"), text: $query, leading: "search")
            ScrollViewReader { proxy in
                Group {
                    if let viewportHeight {
                        ScrollView { grid }.frame(height: viewportHeight)
                    } else {
                        grid
                    }
                }
                .focusable(true)
                .focused($isGridFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space]) { press in
                    handle(press.key)
                    if let cursor { proxy.scrollTo(cursor) }
                    return .handled
                }
            }
        }
        .frame(width: Self.width)
        .onChange(of: query) { _, _ in cursor = nil }
        .onChange(of: isGridFocused) { _, focused in
            if focused, cursor == nil { cursor = selection ?? sections.first?.rows.first?.first }
            if !focused { cursor = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "iconpicker.title", defaultValue: "Project icon"))
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            if sections.allSatisfy({ $0.rows.isEmpty }) {
                Text(String(localized: "iconpicker.empty", defaultValue: "No icon matches."))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .frame(height: Metrics.iconPickerCell)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: Metrics.iconPickerGap) {
                    if let title = section.title {
                        Text(title)
                            .font(Typo.caption)
                            .tracking(Tracking.caption)
                            .textCase(.uppercase)
                            .foregroundStyle(Tok.textTertiary)
                            .padding(.bottom, Space.x1 / 2)
                    }
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: Metrics.iconPickerGap) {
                            ForEach(row, id: \.self) { KIconPickerCell(name: $0, isSelected: $0 == selection, isCursor: $0 == cursor, onPick: pick) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pick(_ name: String) {
        withAnimation(Motion.select) { selection = (selection == name) ? nil : name }
    }

    // MARK: Keyboard — the cursor walks the rows as drawn.
    private func handle(_ key: KeyEquivalent) {
        let rows = sections.flatMap(\.rows)
        guard !rows.isEmpty else { return }
        guard let cursor, let r = rows.firstIndex(where: { $0.contains(cursor) }),
              let c = rows[r].firstIndex(of: cursor) else {
            self.cursor = rows[0][0]
            return
        }
        switch key {
        case .return, .space: pick(cursor)
        case .leftArrow: self.cursor = c > 0 ? rows[r][c - 1] : (r > 0 ? rows[r - 1].last : cursor)
        case .rightArrow: self.cursor = c + 1 < rows[r].count ? rows[r][c + 1] : (r + 1 < rows.count ? rows[r + 1][0] : cursor)
        case .upArrow: if r > 0 { self.cursor = rows[r - 1][min(c, rows[r - 1].count - 1)] }
        case .downArrow: if r + 1 < rows.count { self.cursor = rows[r + 1][min(c, rows[r + 1].count - 1)] }
        default: break
        }
    }
}

private struct KIconPickerCell: View {
    let name: String
    let isSelected: Bool
    let isCursor: Bool
    let onPick: (String) -> Void
    @State private var isHovering = false

    var body: some View {
        Button { onPick(name) } label: {
            Icon(name, size: Metrics.iconL)
                .foregroundStyle(isSelected || isHovering || isCursor ? Tok.textPrimary : Tok.textSecondary)
                .frame(width: Metrics.iconPickerCell, height: Metrics.iconPickerCell)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isSelected ? Tok.dropFill : (isHovering ? Tok.hoverFill : Color.clear))
                )
                .kBorder(isCursor ? Tok.focusRing : (isSelected ? Tok.borderStrong : Color.clear), radius: Radius.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(name)
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
        .help(name.replacingOccurrences(of: "-", with: " "))
        .accessibilityLabel(name.replacingOccurrences(of: "-", with: " "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
