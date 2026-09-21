// Kronos/DesignSystem/KAttributeMenu.swift
// Editing form for a first-class task attribute (effort, priority, …), generic over the
// caller's own option type so the design system never declares a KronosCore-shaped
// enum. The screen leaf passes its real KronosCore.KPriority/KEffort cases in directly.
// Usage:
//   KAttributeMenu(options: KPriority.allCases, selected: task.priority, title: { $0.displayName },
//                  level: { $0.rawValue }, steps: 4, kind: .priority) { task.priority = $0 }
import SwiftUI

public enum KAttributeGlyphKind {
    case priority   // bar-signal glyph
    case effort     // dot-bar glyph
    case none       // no leading glyph, just the menu
}

public struct KAttributeMenu<Option: Identifiable & Hashable>: View {
    let options: [Option]
    let selected: Option
    let title: (Option) -> String
    let level: (Option) -> Int
    let steps: Int
    let kind: KAttributeGlyphKind
    let onPick: (Option) -> Void

    public init(options: [Option], selected: Option, title: @escaping (Option) -> String,
                level: @escaping (Option) -> Int, steps: Int, kind: KAttributeGlyphKind = .none,
                onPick: @escaping (Option) -> Void) {
        self.options = options
        self.selected = selected
        self.title = title
        self.level = level
        self.steps = steps
        self.kind = kind
        self.onPick = onPick
    }

    public var body: some View {
        KMenuButton(text: title(selected)) {
            ForEach(options) { option in
                Button {
                    onPick(option)
                } label: {
                    if option == selected {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(title(option))
                    }
                }
            }
        } leading: {
            leadingGlyph
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch kind {
        case .priority:
            KPriorityIndicator(level: level(selected), of: steps, label: title(selected), size: 14)
        case .effort:
            KEffortIndicator(level: level(selected), of: steps, label: nil, showLabel: false)
        case .none:
            EmptyView()
        }
    }
}
