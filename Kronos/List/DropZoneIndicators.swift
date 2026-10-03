// Kronos/List/DropZoneIndicators.swift
// What the list shows during a drag: the accent insertion line (2 pt, dot at the left, indented
// for the step level), the nest / move-under / attach outline with its ghost line and hint, the
// refusal message, and the preference key through which every row reports its frame.
import SwiftUI
import KronosCore

/// Name of the coordinate space the row frames are measured in: the list's scroll view.
enum DropSpace {
    static let name = "kronos.droplist"
}

struct DropRowFramesKey: PreferenceKey {
    static let defaultValue: [DropRowFrame] = []
    static func reduce(value: inout [DropRowFrame], nextValue: () -> [DropRowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reports this row's frame (task row: `parentID` nil; step row: its task's id) to the list's
    /// drop engine.
    func reportsDropRow(id: UUID, parentID: UUID? = nil) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: DropRowFramesKey.self,
                                   value: [DropRowFrame(id: id, parentID: parentID, frame: geo.frame(in: .named(DropSpace.name)))])
        })
    }
}

struct ListDropIndicators: View {
    let controller: ListDropController
    @Environment(\.kAccent) private var accent

    private static let lineHeight: CGFloat = 2
    private static let dot: CGFloat = 8

    // Every piece is placed with `.position` (layout), never `.offset`, so the frames the live UI
    // test reads off the anchors are the real on-screen frames.
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let feedback = controller.feedback {
                feedbackView(feedback)
            }
            if let toast = controller.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(Typo.metaStrong)
                        .foregroundStyle(Tok.textPrimary)
                        .padding(.horizontal, Space.x3)
                        .padding(.vertical, Space.x2)
                        .background(Tok.overlay, in: Capsule())
                        .overlay(Capsule().strokeBorder(Tok.borderStrong, lineWidth: Metrics.strokeQuiet))
                        .uiTestAnchor("drop.toast")
                        .padding(.bottom, Space.x4)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func feedbackView(_ f: DropFeedback) -> some View {
        let r = f.resolution
        if let y = r.lineY, r.zone.isInsert, f.lineX1 > f.lineX0 {
            insertionLine(x0: f.lineX0, x1: f.lineX1, y: CGFloat(y))
        }
        if r.zone.isInsert, let frame = f.rowFrame, f.hint == .newTask || (f.hint == .promote && r.lineY == nil) {
            let edge = r.zone == .insertAbove ? CGFloat(r.highlightMinY) : CGFloat(r.highlightMaxY)
            edgePill(text(for: f.hint ?? .newTask), x: frame.minX + Space.x3, y: edge, maxWidth: max(40, frame.width - Space.x3))
        }
        if let frame = f.rowFrame, let hint = f.hint {
            switch hint {
            case .nest, .moveUnder:
                outline(frame, dashed: false)
                ghost(frame)
                hintPill(text(for: hint), in: frame, anchor: "drop.hint")
            case .attachLink:
                outline(frame, dashed: true)
                hintPill(text(for: hint), in: frame, anchor: "drop.hint")
            case .newTask, .promote:
                EmptyView()
            }
        }
    }

    // MARK: Pieces

    private func insertionLine(x0: CGFloat, x1: CGFloat, y: CGFloat) -> some View {
        let width = x1 - x0
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(accent)
                .frame(width: width, height: Self.lineHeight)
                .uiTestAnchor("drop.line")
                .position(x: x0 + width / 2, y: y)
            Circle()
                .fill(accent)
                .frame(width: Self.dot, height: Self.dot)
                .position(x: x0, y: y)
        }
    }

    /// A small label at a row edge saying what the drop will create (the line may be hidden in a sorted list).
    private func edgePill(_ text: String, x: CGFloat, y: CGFloat, maxWidth: CGFloat) -> some View {
        Text(text)
            .font(Typo.metaStrong)
            .foregroundStyle(Tok.textPrimary)
            .padding(.horizontal, Space.x2)
            .padding(.vertical, Space.x1 / 2)
            .background(Tok.overlay, in: Capsule())
            .overlay(Capsule().strokeBorder(accent, lineWidth: Metrics.strokeQuiet))
            .uiTestAnchor("drop.hint")
            .frame(width: maxWidth, height: 24, alignment: .leading)
            .position(x: x + maxWidth / 2, y: y - 12)
    }

    private func outline(_ frame: CGRect, dashed: Bool, color: Color? = nil) -> some View {
        KNestOutline(radius: Radius.row, dashed: dashed, color: color)
            .frame(width: frame.width, height: frame.height)
            .uiTestAnchor("drop.outline")
            .position(x: frame.midX, y: frame.midY)
    }

    /// A short indented line under the row: where the new subtask will appear.
    private func ghost(_ frame: CGRect) -> some View {
        let indent = ListDropController.subtaskIndent
        let width = max(0, frame.width - indent)
        return ZStack(alignment: .leading) {
            Rectangle().fill(accent.opacity(Tok.dropLineOpacity)).frame(height: Self.lineHeight)
            Circle().fill(accent.opacity(Tok.dropLineOpacity)).frame(width: Self.dot, height: Self.dot).offset(x: -Self.dot / 2)
        }
        .frame(width: width, height: Self.dot)
        .uiTestAnchor("drop.ghost")
        .position(x: frame.minX + indent + width / 2, y: frame.maxY + Self.lineHeight)
    }

    private func hintPill(_ text: String, in frame: CGRect, anchor: String, prominent: Bool = false) -> some View {
        Text(text)
            .font(Typo.metaStrong)
            .foregroundStyle(Tok.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, Space.x2)
            .padding(.vertical, Space.x1 / 2)
            .background(Tok.overlay, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Tok.borderStrong : accent, lineWidth: Metrics.strokeQuiet))
            .uiTestAnchor(anchor)
            .padding(.trailing, Space.x3)
            .frame(width: frame.width, height: frame.height, alignment: .trailing)
            .position(x: frame.midX, y: frame.midY)
    }

    private func text(for hint: DropFeedback.Hint) -> String {
        DropHintText.text(for: hint)
    }
}

/// What a drop hint says. Nesting and promoting also name the key that does the same from the
/// keyboard (read from the registry, so a rebound key shows its new chord), so the drag teaches
/// the faster path.
@MainActor
enum DropHintText {
    static func text(for hint: DropFeedback.Hint) -> String {
        switch hint {
        case .nest:
            let chord = keys("window.nest")
            return String(format: String(localized: "list.drop.hint.nest.key"), chord)
        case .moveUnder: return String(localized: "list.drop.hint.moveunder")
        case .attachLink: return String(localized: "list.drop.hint.attach")
        case .newTask: return String(localized: "list.drop.hint.newtask")
        case .promote:
            let chord = keys("window.unnest")
            return String(format: String(localized: "list.drop.hint.promote.key"), chord)
        }
    }

    /// The chord as printed caps, e.g. "⌘]" (HR layout prints its own character).
    static func keys(_ id: String) -> String {
        (HotkeyRegistry.current(for: id)?.displayKeys ?? []).joined()
    }
}
