// Kronos/QuickAdd/QuickAddTemplates.swift
// Quick add `/` prefix: typing `/` lists the saved templates, `/name` narrows them, Return
// creates the task (with its subtasks) and appends the rest of the line to its title
// (`/weekly review for Q4`). The parsing lives in Core (`TemplateQuery`, unit tested); this
// file is the submit hook and the list that replaces the legend while a `/` is typed.
// A line starting with `/` that matches no template falls through to a plain task, so a title
// like "/etc cleanup" still works.
import SwiftUI
import KronosCore

@MainActor
enum QuickAddTemplates {

    enum Outcome {
        /// Task made: the caller clears the field exactly as after a normal create and posts the
        /// one acknowledgement (QuickAddAck), so a template add reads like any other add.
        case created(KTask)
        /// Bare `/`: Return completes the first suggestion instead of making a task titled "/".
        case fill(String)
        /// Bare `/` with no templates saved: nothing to do.
        case ignore
        /// Not a template line (or it matches nothing): create a plain task as usual.
        case notATemplate
    }

    static func submit(text: String, model: AppModel, isWaiting: Bool) -> Outcome {
        let store = TemplateStore.shared
        guard TemplateQuery.isTemplateInput(text) else { return .notATemplate }
        if TemplateQuery.queryText(text).isEmpty {
            guard let first = TemplateQuery.suggestions(for: text, in: store.templates).first else { return .ignore }
            return .fill("/" + first.name + " ")
        }
        guard let hit = TemplateQuery.resolve(text, in: store.templates) else { return .notATemplate }
        // Same status rule as every other quick add entry: a task with no date lands in
        // Someday, the Waiting toggle always wins (ListScopeDefaults, hand-tabled in Core).
        let today = Day.today(calendar: KronosLocale.calendar)
        let defaults = ListScopeDefaults.apply(scope: nil, explicitDueDay: nil, today: today, isWaiting: isWaiting)
        let task = model.store.createFromTemplate(hit.template, rest: hit.rest, status: defaults.status, dueDay: defaults.dueDay)
        model.didMutate()
        return .created(task)
    }
}

/// The list shown under the field while the line starts with `/`. Clicking a row completes the
/// name (`/weekly review `) so the rest of the title can be typed straight after it.
struct QuickAddTemplateList: View {
    let templates: [TaskTemplate]
    let text: String
    let onPick: (TaskTemplate) -> Void

    private var matches: [TaskTemplate] { TemplateQuery.suggestions(for: text, in: templates) }

    /// Worth showing only when it helps: some template matches, or there are none at all yet
    /// (then it teaches where they come from). A `/` line that matches nothing falls back to the
    /// normal legend and chips.
    static func isShowing(text: String, templates: [TaskTemplate]) -> Bool {
        guard TemplateQuery.isTemplateInput(text) else { return false }
        return templates.isEmpty ? TemplateQuery.queryText(text).isEmpty
                                 : !TemplateQuery.suggestions(for: text, in: templates).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            if templates.isEmpty {
                Text(String(localized: "quickadd.template.empty"))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textTertiary)
            } else {
                ForEach(Array(matches.prefix(6).enumerated()), id: \.element.id) { index, t in
                    row(t, isFirst: index == 0)
                }
                Text(String(localized: "quickadd.template.hint"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .padding(.top, Space.x1)
            }
        }
    }

    private func row(_ t: TaskTemplate, isFirst: Bool) -> some View {
        Button { onPick(t) } label: {
            HStack(spacing: Space.x2) {
                Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                Text(t.name)
                    .font(Typo.rowStrong)
                    .foregroundStyle(isFirst ? Tok.textPrimary : Tok.textSecondary)
                    .lineLimit(1)
                if t.title != t.name {
                    Text(t.title)
                        .font(Typo.row)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isFirst { KKeyHint("⏎") }
            }
            // Frame + contentShape INSIDE the label: a plain-style button is pressable only on
            // its opaque label pixels.
            .frame(height: Metrics.minHit + Space.x1, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.name)
    }
}
