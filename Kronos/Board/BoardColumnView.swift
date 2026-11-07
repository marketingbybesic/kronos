// Kronos/Board/BoardColumnView.swift
// One Board column: a plain-word header with its count, a vertical scroll of cards, and the
// drop target for a card dragged in from anywhere else in the app.
import SwiftUI
import KronosCore

struct BoardColumnView: View {
    @Bindable var model: AppModel
    let column: BoardColumn
    let tasks: [KTask]
    @Binding var dropTarget: BoardColumn?

    private var isDropTarget: Bool { dropTarget == column }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            header
            ScrollView {
                LazyVStack(spacing: Space.x1) {
                    ForEach(tasks) { task in
                        BoardCardView(model: model, task: task, column: column)
                    }
                }
            }
        }
        .padding(Space.x2)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tok.bg)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(isDropTarget ? Tok.borderActive : Tok.hairline,
                              lineWidth: isDropTarget ? Metrics.ringWidth : Metrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .animation(Motion.curve(Motion.fast), value: isDropTarget)
        .onDrop(of: BoardColumnDropDelegate.types,
               delegate: BoardColumnDropDelegate(column: column, model: model, today: Day.today(), isTargeted: $dropTarget))
    }

    private var header: some View {
        HStack(spacing: Space.x1) {
            Text(String(localized: String.LocalizationValue(column.titleKey)))
                .font(Typo.sectionHdr)
                .foregroundStyle(Tok.textSecondary)
            KBadge("\(tasks.count)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.x1)
        .uiTestAnchor("board.column.\(column.rawValue).header")
    }
}
