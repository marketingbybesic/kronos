// Kronos/List/ListMissingGroup.swift
// A list sorted by an attribute (deadline, effort, estimate, project) ends with the tasks that LACK it
// under their own header, "No deadline (3)". The header folds the group, and offers "Suggest": the
// person's triage pipeline proposes a value for those tasks, listed right under the header; "Fill"
// writes them all (or one) in a single undo step. Nothing changes until the person taps Fill, and with
// the AI policy off the button is not there at all.
import SwiftUI
import KronosCore

/// Whether the missing group is open. Per session; shared by every reader of the list so keyboard
/// order and drawing agree (like the Earlier section).
@MainActor
@Observable
final class ListMissingState {
    static let shared = ListMissingState()
    var isExpanded = true
    private init() {}
}

struct ListMissingHeader: View {
    @Bindable var model: AppModel
    let key: KSortKey
    /// The missing tasks that can be asked about (open ones).
    let ids: [UUID]
    let scope: ListScope
    /// Every task in the group, closed ones included: what the header counts.
    let total: Int
    @Bindable private var state = ListMissingState.shared
    @Bindable private var suggest = ListMissingSuggest.shared

    private var subject: String { ListMissingSuggest.subjectKey(scope: scope, key: key) }
    private var phase: ListMissingSuggest.Phase { suggest.phase(for: subject) }

    var body: some View {
        GroupHeader(title: Self.headerText(key, count: total), isCollapsed: !state.isExpanded, onToggle: {
            withAnimation(Motion.curve(Motion.fast)) { state.isExpanded.toggle() }
        }, anchor: "list.missing.header", trailing: {
            if ListMissingSuggest.mayAsk(model), !ids.isEmpty { suggestControls }
        })
    }

    @ViewBuilder private var suggestControls: some View {
        switch phase {
        case .idle, .none:
            if phase == .none {
                Text(String(localized: "list.missing.none"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .uiTestAnchor("list.missing.none")
            }
            Button(String(localized: "list.missing.suggest")) {
                suggest.ask(model: model, ids: ids, key: key, scope: scope)
            }
            .kButton(.ghost, size: .compact)
            .help(String(localized: "list.missing.suggest.help"))
            .uiTestAnchor("list.missing.suggest")
        case .asking:
            HStack(spacing: Space.x1) {
                ProgressView().controlSize(.small)
                Text(String(localized: "list.missing.asking"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            .uiTestAnchor("list.missing.asking")
        case .ready:
            Button(String(format: String(localized: "list.missing.fill"), suggest.suggestions.count)) {
                suggest.fill(model: model)
            }
            .kButton(.secondary, size: .compact)
            .uiTestAnchor("list.missing.fill")
            Button(String(localized: "list.missing.dismiss")) { suggest.dismiss() }
                .kButton(.ghost, size: .compact)
                .uiTestAnchor("list.missing.dismiss")
        }
    }

    /// "No deadline (3)": one string per attribute, so each reads naturally in both languages.
    static func headerText(_ key: KSortKey, count: Int) -> String {
        let format: String
        switch key {
        case .deadline: format = String(localized: "list.missing.header.deadline")
        case .effort: format = String(localized: "list.missing.header.effort")
        case .estimateMinutes: format = String(localized: "list.missing.header.estimate")
        case .project: format = String(localized: "list.missing.header.project")
        default: return String(format: String(localized: "list.missing.header.generic"), ViewOptionsMapper.sortField(key).name, count)
        }
        return String(format: format, count)
    }
}

/// What Fill would write, one line per task: its title and the proposed value — ordinary
/// (non-sticky) rows under the group, not inside the sticky `GroupHeader` itself.
struct ListMissingSuggestionLines: View {
    @Bindable var model: AppModel
    let key: KSortKey
    let scope: ListScope
    @Bindable private var suggest = ListMissingSuggest.shared

    private var subject: String { ListMissingSuggest.subjectKey(scope: scope, key: key) }

    var body: some View {
        if suggest.phase(for: subject) == .ready {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggest.suggestions, id: \.taskID) { sugg in
                    HStack(spacing: Space.x2) {
                        Text(model.store.task(sugg.taskID)?.title ?? "")
                            .font(Typo.row)
                            .foregroundStyle(Tok.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: Space.x2)
                        Text(ListMissingSuggest.text(sugg.value))
                            .font(Typo.metaStrong)
                            .foregroundStyle(Tok.textPrimary)
                            .lineLimit(1)
                        Button(String(localized: "list.missing.fill.one")) { suggest.fill([sugg.taskID], model: model) }
                            .kButton(.ghost, size: .compact)
                    }
                    .padding(.leading, ChildRowGeometry.listRowContentInset + Metrics.listRowLeading + Space.x4)
                    .padding(.trailing, ChildRowGeometry.listRowContentInset + Metrics.listRowTrailing)
                    .frame(minHeight: Metrics.minHit)
                    .uiTestAnchor("list.missing.line.\(sugg.taskID.uuidString)")
                }
            }
        }
    }
}
