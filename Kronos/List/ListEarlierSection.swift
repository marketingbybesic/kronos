// Kronos/List/ListEarlierSection.swift
// Today ends with a collapsed "Earlier (n)" section: tasks carried from earlier days (or whose
// day has passed) sit there instead of mixing into today's rows. Its header offers a fresh start
// for all of them at once: Today, Tomorrow or Someday, ONE undo step (TaskStore.freshStart).
import SwiftUI
import KronosCore

/// Whether the Earlier section is open. Per session (a fresh window starts collapsed); shared by
/// every reader of the list so keyboard order and rendering agree.
@MainActor
@Observable
final class ListEarlierState {
    static let shared = ListEarlierState()
    /// What the person chose this session; nil until they open or close the section themselves.
    private(set) var userChoice: Bool?
    /// Open without being asked: Today has nothing of its own, so a collapsed section would
    /// leave a bare "0" over tasks that are waiting.
    var autoOpened = false
    var isExpanded: Bool {
        get { userChoice ?? autoOpened }
        set { userChoice = newValue }
    }
    /// Forgets the person's choice (a fresh session; the live test).
    func resetChoice() { userChoice = nil; autoOpened = false }
    private init() {}
}

/// Moves every Earlier task to one place in a single undo step and says so in the undo pill.
@MainActor
enum ListEarlier {
    static func freshStart(_ ids: [UUID], to target: FreshStartTarget, model: AppModel) {
        guard !ids.isEmpty else { return }
        let depth = model.store.undoDepth
        model.store.freshStart(ids: ids, to: target)
        guard model.store.undoDepth != depth else {
            model.didMutate()   // refresh-only: nothing moved, nothing to announce
            return
        }
        let message: String
        switch target {
        case .today: message = String(format: String(localized: "today.earlier.moved.today"), ids.count)
        case .tomorrow: message = String(format: String(localized: "today.earlier.moved.tomorrow"), ids.count)
        case .someday: message = String(format: String(localized: "today.earlier.moved.someday"), ids.count)
        }
        model.commit(message)
    }
}

/// The header row of the Earlier section: a disclosure with the count, then the three moves.
struct ListEarlierHeader: View {
    @Bindable var model: AppModel
    let ids: [UUID]
    @Bindable private var state = ListEarlierState.shared

    /// Nothing of Today's own is listed above this header.
    private var todayIsEmpty: Bool { ListContext(model: model).currentCount == 0 }

    var body: some View {
        HStack(spacing: Space.x2) {
            Button {
                withAnimation(Motion.curve(Motion.fast)) { state.isExpanded.toggle() }
            } label: {
                HStack(spacing: Space.x1) {
                    Icon(state.isExpanded ? "chevron-down" : "chevron-right", size: Metrics.iconXS)
                        .foregroundStyle(Tok.textTertiary)
                        .accessibilityHidden(true)
                    Text(String(format: String(localized: "today.earlier.header"), ids.count))
                        .font(Typo.metaStrong)
                        .foregroundStyle(Tok.textSecondary)
                }
                .frame(minHeight: Metrics.minHit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(state.isExpanded ? String(localized: "today.earlier.a11y.open")
                                                 : String(localized: "today.earlier.a11y.closed"))
            .uiTestAnchor("today.earlier.header")
            Spacer(minLength: Space.x2)
            move(.today, String(localized: "today.earlier.today"), anchor: "today.earlier.today")
            move(.tomorrow, String(localized: "today.earlier.tomorrow"), anchor: "today.earlier.tomorrow")
            move(.someday, String(localized: "today.earlier.someday"), anchor: "today.earlier.someday")
        }
        .padding(.leading, ChildRowGeometry.listRowContentInset + Metrics.listRowLeading)
        .padding(.trailing, ChildRowGeometry.listRowContentInset + Metrics.listRowTrailing)
        .frame(minHeight: Metrics.groupHeaderHeight)
        .onChange(of: todayIsEmpty, initial: true) { _, empty in state.autoOpened = empty }
    }

    private func move(_ target: FreshStartTarget, _ title: String, anchor: String) -> some View {
        Button(title) { ListEarlier.freshStart(ids, to: target, model: model) }
            .kButton(.ghost, size: .compact)
            .help(String(format: String(localized: "today.earlier.move.help"), ids.count, title))
            .uiTestAnchor(anchor)
    }
}
