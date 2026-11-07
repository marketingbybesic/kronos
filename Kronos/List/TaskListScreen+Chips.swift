// Kronos/List/TaskListScreen+Chips.swift
// The active-rules bar's chips and their removal — split from TaskListScreen.swift to keep that
// file under the project's 500-line budget (gate-files.mjs), the same split as +Parts/+Bulk.
import SwiftUI
import KronosCore

extension TaskListScreen {
    /// The filter as chips and the rule count see it: a saved view's own project is where the view lives, not a
    /// rule to show or remove (it is the locked row in the options popover), so it is left out.
    private func visibleFilter(_ options: ViewOptions) -> KFilter {
        var f = options.filter
        if ListViewReset.pin(model: model, scope: model.scope) != nil { f.clear(.project) }
        return f
    }

    func ruleCount(_ ctx: ListContext) -> Int {
        ViewOptionsMapper.activeRuleCount(sort: ctx.options.sort, filter: visibleFilter(ctx.options))
    }

    func chips(_ ctx: ListContext) -> [KActiveRulesBar.RuleChip] {
        var chips: [KActiveRulesBar.RuleChip] = []
        if ctx.options.sort != KSortDescriptor.default {
            for (i, d) in ctx.options.sort.enumerated() {
                chips.append(.init(id: "sort.\(i)", text: ViewOptionsMapper.sortChipText(d), onTap: { showPopover = true }, onRemove: {
                    var opts = ctx.options
                    opts.sort.remove(at: i)
                    if opts.sort.isEmpty { opts.sort = KSortDescriptor.default }
                    model.setOptions(opts, for: model.scope)
                }))
            }
        }
        let shownFilter = visibleFilter(ctx.options)
        if shownFilter != .empty {
            let texts = ViewOptionsMapper.filterChipTexts(shownFilter, projectName: projectName, areaName: areaName, labelName: labelName)
            for (i, text) in texts.enumerated() {
                chips.append(.init(id: "filter.\(i)", text: text, onTap: { showPopover = true }, onRemove: {
                    removeFilterRule(at: i, from: ctx.options)
                }))
            }
        }
        return chips
    }

    private func removeFilterRule(at index: Int, from options: ViewOptions) {
        let shown = visibleFilter(options)
        let rules = ViewOptionsMapper.filterRules(from: shown, projectName: projectName, areaName: areaName, labelName: labelName)
        guard rules.indices.contains(index) else { return }
        var opts = options
        opts.filter = ViewOptionsMapper.clearing(ViewOptionsMapper.filterFieldID(rules[index].field), from: options.filter)
        model.setOptions(opts, for: model.scope)
    }

    func resetOptions() {
        ListViewReset.clearAll(model: model, scope: model.scope)
    }
    // MARK: - Name lookups (chips, filter builder)

    private func projectName(_ id: UUID) -> String? { model.store.allProjects().first { $0.id == id }?.name }
    private func areaName(_ id: UUID) -> String? { model.store.allProjects().compactMap(\.area).first { $0.id == id }?.name }
    private func labelName(_ id: UUID) -> String? {
        model.store.allTasks().flatMap { $0.labels ?? [] }.first { $0.id == id }?.name
    }
}
