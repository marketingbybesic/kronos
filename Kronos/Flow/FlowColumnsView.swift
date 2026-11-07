// Kronos/Flow/FlowColumnsView.swift
// The depth-column grid (E2/E3): one `VStack` per `FlowLayout.Column`, laid out left to right,
// with the dependency edges drawn in a `Canvas` BEHIND the cards (E3: straight or one-elbow
// orthogonal lines only). Each card reports its own frame via a preference, in the SAME named
// coordinate space the Canvas reads, so the edges always track the cards exactly — no separate
// geometry model to keep in sync by hand.
//
// E6: vertical scroll always; horizontal scroll only past 4 columns. No pan or zoom.
import SwiftUI
import KronosCore

private struct FlowCardFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct FlowColumnsView: View {
    static let coordinateSpace = "flow.columns"

    @Bindable var model: AppModel
    let result: FlowLayout.Result
    let tasksByID: [UUID: KTask]
    let runStore: RunStore?
    let focusedID: UUID?
    /// Selected id plus its upstream/downstream chain; empty = nothing dims (no selection).
    let highlighted: Set<UUID>
    /// Plan F's "Milestones" gate mark (FlowScreen.FlowContext.gateIDs) — >= 2 open dependents.
    let gateIDs: Set<UUID>
    let headerText: (FlowLayout.Column) -> String
    let onSelect: (UUID) -> Void

    @State private var frames: [UUID: CGRect] = [:]

    /// E6: scroll horizontally once the columns' fixed content width would exceed the VISIBLE
    /// pane (`GeometryReader` below measures it) — not a raw column-count threshold, so the
    /// last column never clips with no way to reach it once the inspector (or a narrow window)
    /// eats width down to 2 or 3 columns' worth, not only past 4.
    private func scrollAxes(available: CGFloat) -> Axis.Set {
        let needsScroll = FlowColumnScroll.needsHorizontalScroll(
            columnCount: result.columns.count, cardWidth: Double(Metrics.flowCardWidth),
            columnGap: Double(Metrics.flowColumnGap), horizontalPadding: Double(Space.x3 * 2),
            available: Double(available))
        return needsScroll ? [.vertical, .horizontal] : .vertical
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(scrollAxes(available: geo.size.width)) {
                columns
                    .background(edgesCanvas)
                    .padding(Space.x3)
            }
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(FlowCardFramePreference.self) { frames = $0 }
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: Metrics.flowColumnGap) {
            ForEach(result.columns) { column in
                columnView(column)
            }
        }
    }

    private func columnView(_ column: FlowLayout.Column) -> some View {
        VStack(alignment: .leading, spacing: Metrics.flowCardGap) {
            Text(headerText(column))
                .font(Typo.sectionHdr)
                .foregroundStyle(Tok.textSecondary)
                .frame(height: Metrics.flowColumnHeaderHeight, alignment: .leading)
            ForEach(column.taskIDs, id: \.self) { id in
                if let task = tasksByID[id] {
                    FlowCardView(model: model, task: task, isFocused: id == focusedID,
                                isDimmed: !highlighted.isEmpty && !highlighted.contains(id),
                                isGate: gateIDs.contains(id), runStore: runStore, onSelect: { onSelect(id) })
                        .background(cardFrameReporter(id))
                }
            }
        }
    }

    private func cardFrameReporter(_ id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: FlowCardFramePreference.self,
                                   value: [id: geo.frame(in: .named(Self.coordinateSpace))])
        }
    }

    private var edgesCanvas: some View {
        Canvas { context, _ in
            for edge in result.edges {
                guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
                let active = highlighted.isEmpty || (highlighted.contains(edge.from) && highlighted.contains(edge.to))
                let color = active ? Tok.borderActive : Tok.hairline
                context.stroke(path(from: from, to: to), with: .color(color), lineWidth: Metrics.hairline)
            }
        }
        .allowsHitTesting(false)
    }

    /// Straight when the two cards already line up vertically; otherwise one elbow (horizontal
    /// out of the prerequisite's trailing edge, one 90° turn, vertical into the dependent's
    /// leading edge) — never more than one bend.
    private func path(from: CGRect, to: CGRect) -> Path {
        let start = CGPoint(x: from.maxX, y: from.midY)
        let end = CGPoint(x: to.minX, y: to.midY)
        var path = Path()
        path.move(to: start)
        if abs(start.y - end.y) < 1 {
            path.addLine(to: end)
        } else {
            path.addLine(to: CGPoint(x: end.x, y: start.y))
            path.addLine(to: end)
        }
        return path
    }
}
