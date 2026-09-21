// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols without touching any
// file this leaf does not own.
#if !RELEASE
// Kronos/List/ListSnapshots.swift
// Named screens for the snapshot harness (SnapshotHarness merges this in). Popovers can't
// be captured while presented, so `list.viewoptions` exposes the popover's CONTENT view
// directly. `list.rules` seeds two sort rules + two filter rules onto the current scope
// so the chip bar renders. `list.empty` picks a scope with zero matches under the seed.
// `list.columns` (checked by scripts/column-check.mjs) creates 5 fresh tasks
// through `model.store` — independent of the 37-task seed's order or contents — that
// EVERY have a priority set (so the priority glyph is the left-most trailing item in
// every row, per the oracle's contract) and short titles (so no title ink reaches the
// oracle's trailing-region scan), differing in everything else: full attributes, priority
// only, priority + overdue carry pill, priority + effort with no deadline, priority +
// subtasks + recurrence. Pinned to the very top of Manual order so they are rows 1-5
// regardless of what else the seed contains.
//
// IMPORTANT: `screens(model:)` is called once up front to build the FULL dictionary of
// every named screen this leaf offers, before the harness picks which single key to
// render (SnapshotHarness.swift). Mutating the shared `model` directly inside this
// function — setting `model.scope` or calling `model.setOptions` eagerly — leaks into
// whichever screen actually gets rendered, since all three closures run regardless of
// which one is chosen. Every mutation below is deferred to `.onAppear`, so it only fires
// for the screen the harness actually displays.
import SwiftUI
import KronosCore

@MainActor
enum ListSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "list.viewoptions": AnyView(viewOptionsContent(model: model)),
            "list.rules": AnyView(rulesList(model: model)),
            "list.empty": AnyView(emptyList(model: model)),
            "list.columns": AnyView(columnsList(model: model)),
            "list.saveview": AnyView(saveViewSheet()),
            "list.nowcard": AnyView(nowCardList(model: model)),
            "list.editing": AnyView(editingList(model: model)),
        ]
    }

    /// A row mid double-click-edit: there is no double-click to send inside the
    /// offscreen harness, so `ListRowView.snapshotEditingTaskID` (set here before the row ever
    /// appears) puts that ONE row straight into its edit state on `.onAppear` — same technique
    /// as every other fixture in this file driving state through `.onAppear`, just reaching a
    /// row's own private state instead of `model`'s. 8 sibling rows join it (same count/reason
    /// as `columnsList` below — one row alone left a 900x420 shot under the gate's 2% ink floor).
    private static func editingList(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.chromaMode = .calm
                model.setOptions(.default, for: .all)
                model.scope = .all
                model.searchText = "Edit row:"
                let count = 8
                let floor = (model.store.allTasks().map(\.sortIndex).min() ?? 0) - Double(count) * 1024
                var editID: UUID?
                for i in 0..<count {
                    let t = model.store.createNoUndo(title: "Edit row: task \(i + 1)", notes: "", project: nil,
                                                      status: .todo, priority: .medium, dueDay: nil)
                    model.store.updateNoUndo(t.id) { $0.sortIndex = floor + Double(i) * 1024 }
                    if i == 0 { editID = t.id }
                }
                model.selectedTaskID = editID
                ListRowView.snapshotEditingTaskID = editID
                model.didMutate()
            }
    }

    /// A focus task with a first move AND a project, pinned so the Now card renders
    /// regardless of the 37-task seed's own contents/order (G3/G9). Created fresh rather
    /// than picked from the seed, same reasoning as `columnsList` below.
    private static func nowCardList(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.scope = .all
                // Colour borrowed from the seed's own projects (never a literal hex outside
                // DesignSystem) — just the first one, any real seed colour is saturated enough.
                // Icon fixed to the raw SF Symbol "briefcase.fill" (a dot in the name opts out
                // of Icon's Lucide map — allowed, see Icon.swift) rather than a seed project's
                // own icon: measured against several solid-looking candidates, a single
                // Metrics.iconM glyph is a small enough patch that most SF Symbols'
                // coloured-pixel footprint undershoots `--expect-color`'s 0.01% floor —
                // "briefcase.fill" was the most solid of those tried (0.018%, G5).
                let projects = model.store.allProjects()
                guard let colorHex = projects.first?.colorHex else { return }
                let project = model.store.createProject(name: "Acme", colorHex: colorHex, icon: "briefcase.fill", area: nil)
                let today = Day.today()
                let t = model.store.createNoUndo(title: "Send the September invoice to Acme", notes: "",
                                                  project: project, status: .todo, priority: .medium, dueDay: today + 4)
                model.store.updateNoUndo(t.id) {
                    $0.firstMove = "Open the invoice template and fill in the line items."
                    $0.effortRaw = KEffort.m.rawValue
                }
                model.pinnedFocusTaskID = t.id
                model.didMutate()
            }
    }

    /// The "Save as view…" sheet content on its own — same reason `list.viewoptions`
    /// exposes the popover content directly (popovers can't be captured while presented).
    private static func saveViewSheet() -> some View {
        ListSaveViewSheet(name: "My view", onSave: { _ in }, onCancel: {})
    }

    /// Three sort rules + two filter rules that actually match rows in the 37-task seed —
    /// the seed carries no `effort` (every task defaults to `.none`), so a filter keyed on
    /// effort would exclude everything and the gate's ink threshold could never pass on
    /// real data. Priority + status are populated in the seed, so those are used instead.
    /// The status rule is negated ("Status is not Waiting, Someday") so `list.viewoptions`
    /// shows a live `is not` row and `list.rules`' chip bar shows its `is not` chip (G4).
    /// A third sort rule (Title) — the popover's own content, not decoration — gives the
    /// `list.viewoptions:400x680` shot real margin over its ink floor instead of landing
    /// right on the threshold (measured 3.95-4.0% with two rules; noise-prone at that size).
    private static func seedRules(_ model: AppModel, scope: ListScope) {
        var opts = model.options(for: scope)
        opts.sort = [.desc(.priority), .asc(.deadline), .asc(.title)]
        opts.filter.priorities = [KPriority.medium.rawValue, KPriority.high.rawValue]
        opts.filter.statuses = [KStatus.waiting.rawValue, KStatus.someday.rawValue]
        opts.filter.setNegated(.statuses, true)
        model.setOptions(opts, for: scope)
    }

    // Top-anchored (not vertically centered): a real popover hugs its own content height
    // instead of centering in whatever frame the harness happens to render at, so this
    // snapshot's ink match what a person actually sees, not the same content thinned out
    // by empty space above and below.
    private static func viewOptionsContent(model: AppModel) -> some View {
        VStack(spacing: 0) {
            ListViewOptionsPopoverContent(model: model, scope: model.scope)
                .padding(Space.x4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tok.bg)
        .onAppear { seedRules(model, scope: model.scope) }
    }

    private static func rulesList(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear { seedRules(model, scope: model.scope) }
    }

    private static func emptyList(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.scope = .waiting
                var opts = model.options(for: .waiting)
                opts.filter.text = "zzz-no-match-zzz"
                model.setOptions(opts, for: .waiting)
            }
    }

    /// Creates 5 fresh tasks (not drawn from the 37-task seed, whose order/contents may
    /// change) that ALL have a priority set and short titles, pinned to the very top of
    /// Manual order, each varying a different combination of the other attributes — the
    /// exact contract `scripts/column-check.mjs` requires so it can use the priority
    /// glyph's left edge as the one measurement every row shares.
    private static func columnsList(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.scope = .all
                // Calm: this fixture's whole contract is the priority glyph's left edge at
                // a fixed x on a 420pt-tall frame with no chip bar (column-check.mjs skips
                // only its own `--top 120` px). The Now card sits above the list in every
                // other mode (G9), which is correct there but would push these rows out of
                // the oracle's frame here — test setup choosing its scenario, same as
                // emptyList picking `.waiting` below, not the screen branching on chroma.
                model.chromaMode = .calm
                model.setOptions(.default, for: .all)   // no active sort/filter rules -> no chip bar
                // Search filters the view down to just these 5 rows, so no seed task with a
                // long real title reaches the oracle's trailing-region scan (its own doc
                // comment: "list.png isn't gated for this reason — real titles are long").
                // `searchText` isn't part of ViewOptions/the chip bar, so this doesn't
                // trigger the "no active rules" requirement above.
                model.searchText = "Col row:"

                let today = Day.today()
                // Titles stay under 25 chars (oracle contract). 6 distinct combinations
                // covers the contract; two are repeated with a different priority so the
                // 420pt viewport fills with enough rows to clear the shot gate's own ink
                // floor. Every row now also carries an effort (none showed no dots at all,
                // which is real content, not padding, but this screen also runs in Calm —
                // which hides the header's live count — so every row pulling its own
                // weight is what keeps this at a comfortable margin over the floor rather
                // than right on it.
                let specs: [(title: String, priority: KPriority, effort: KEffort, due: Int?, subtasks: Int, recurring: Bool)] = [
                    ("Col row: all attrs set",  .high,   .m,    today + 2, 0, false),
                    ("Col row: priority only",  .medium, .xs,   nil,       0, false),
                    ("Col row: overdue pill",   .low,    .s,    today - 3, 0, false),
                    ("Col row: no deadline set", .urgent, .s,    nil,      0, false),
                    ("Col row: has subtasks",   .medium, .m,    today + 5, 2, true),
                    ("Col row: effort no due",  .high,   .l,    nil,       0, false),
                    ("Col row: overdue again",  .urgent, .m,    today - 1, 0, false),
                    ("Col row: subtasks again", .low,    .xl,   today + 9, 3, false),
                ]
                // Pinned above every other manual-order task (min existing index - 1024*N),
                // so these 5 are rows 1-5 regardless of what else the store contains.
                let floor = (model.store.allTasks().map(\.sortIndex).min() ?? 0) - Double(specs.count) * 1024
                for (i, spec) in specs.enumerated() {
                    let t = model.store.createNoUndo(title: spec.title, notes: "", project: nil,
                                                      status: .todo, priority: spec.priority, dueDay: spec.due)
                    model.store.updateNoUndo(t.id) {
                        $0.sortIndex = floor + Double(i) * 1024
                        $0.effortRaw = spec.effort.rawValue
                        if spec.recurring { $0.recurrenceRule = "FREQ=DAILY" }
                    }
                    for s in 0..<spec.subtasks {
                        model.store.addSubtaskNoUndo(t.id, title: "Step \(s + 1)")
                        if s == 0 { model.store.toggleSubtaskNoUndo(t.orderedSubtasks.first?.id ?? UUID(), isDone: true) }
                    }
                }
                model.didMutate()
            }
    }
}
#endif
