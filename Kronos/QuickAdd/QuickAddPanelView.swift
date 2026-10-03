// Kronos/QuickAdd/QuickAddPanelView.swift
// The global quick add panel's SwiftUI content. The field, its pills and its suggestion list
// are the shared entry field (Kronos/Shared/EntryField); this view adds what only the panel
// has: the plain-word syntax LEGEND (opens by itself for the first few adds, then only on "Show
// syntax", a remembered choice), a placeholder whose example cycles one token at a time, the
// context chips of the app it was opened over, the `/` template list, the Waiting toggle and the
// key hints. Return adds and closes, Command-Return adds and stays open, Option-Return adds and
// keeps the pills (a batch into one project), Shift-Return starts a subtask line, Return on an
// empty field closes (QuickAddPolicy.onReturn). Every other entry surface keeps "Return adds
// and clears".
//
// The field is multi-line (TaskOutline grammar: "a > b > c" on one line, or Tab-indented /
// bulleted lines under a task) so subtasks can be added from quick add too. Submission runs
// through the shared `QuickAddCreate.create`, the same place `ListInlineNewTaskRow` uses, so
// every add field understands identical text.
import SwiftUI
import AppKit
import KronosCore

struct QuickAddPanelView: View {
    let model: AppModel
    var hotkeyNotice: String?
    var seedText: String = ""
    /// The panel's job is done: close and give focus back (Return after an add, Return on an
    /// empty field).
    var onSubmit: () -> Void
    var onClose: () -> Void

    /// Text + pills + suggestions (Kronos/Shared/EntryField). Owned by `QuickAddController` when the
    /// panel is real (so the live UI test can read it), created here for a snapshot.
    @State private var entry: EntryFieldModel
    /// Chips read from the app the panel was opened over (nil: opened over Kronos, a snapshot).
    private let context: QuickAddContextState?
    /// Whether the legend shows now: by itself for the first few adds, else the remembered choice.
    @State private var legendShown: Bool
    // A gap this fixes: there was no Waiting control in quick add at all. Resets to off each
    // time the panel opens fresh (same as `text`): a leftover toggle from the last entry
    // silently waiting-ing the next one would be worse than retyping it.
    @State private var isWaiting: Bool

    /// True while the text is still the restored (<= 60 s) draft, untouched: it opens selected so
    /// typing replaces it, and a faint "Draft" caption says why there is text already.
    @State private var isDraft: Bool
    /// Which example the placeholder shows (cycles while the field is empty; fixed under Reduce
    /// Motion and in snapshots).
    @State private var ghostIndex: Int
    private let ghostCycles: Bool

    /// Remembered "Show syntax" choice (default collapsed). Through `KronosEnv.defaults`, so a
    /// test run never writes the person's own domain.
    static let legendOpenKey = "kronos.quickadd.legendOpen"
    /// Seconds each placeholder example stays.
    static let ghostInterval: Duration = .seconds(3)

    init(model: AppModel, hotkeyNotice: String? = nil, seedText: String = "", seedIsDraft: Bool = false,
         seedLegendPinned: Bool? = nil, seedAddsCount: Int? = nil, seedPills: [EntryPill] = [],
         entry: EntryFieldModel? = nil, context: QuickAddContextState? = nil, seedIsWaiting: Bool = false,
         seedGhost: Int? = nil, onSubmit: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.hotkeyNotice = hotkeyNotice
        self.seedText = seedText
        self.onSubmit = onSubmit
        self.onClose = onClose
        self.context = context
        self._entry = State(initialValue: entry ?? EntryFieldModel(text: seedText, pills: seedPills))
        let pinned = seedLegendPinned ?? KronosEnv.defaults.bool(forKey: Self.legendOpenKey)
        // A snapshot that pins the legend states it explicitly; one that does not is not a first run.
        let adds = seedAddsCount ?? (seedLegendPinned != nil ? QuickAddPolicy.legendAutoOpenAdds
                                     : KronosEnv.defaults.integer(forKey: QuickAddController.addsCountKey))
        self._legendShown = State(initialValue: QuickAddPolicy.legendOpens(pinned: pinned, addsSoFar: adds))
        self._isDraft = State(initialValue: seedIsDraft && !seedText.isEmpty)
        self._isWaiting = State(initialValue: seedIsWaiting)
        self._ghostIndex = State(initialValue: seedGhost ?? 0)
        self.ghostCycles = seedGhost == nil && !KronosEnv.isSnapshot
    }

    /// The outline's first item: the pills summarise its task-line syntax. Later items (more
    /// tasks, or that item's own subtasks) are covered by `subtaskSummary` below.
    private var firstItem: TaskOutline.Item? { TaskOutline.parse(entry.text).first }

    /// "2 subtasks: find template, fill in prices" under the chips, or nil when the first task
    /// has none. A flat multi-task list (no subtasks anywhere) has nothing to summarise here —
    /// each of those lines becomes its own task on submit, same as typing them one at a time.
    private var subtaskSummary: String? {
        guard let subtasks = firstItem?.subtasks, !subtasks.isEmpty else { return nil }
        // Croatian needs one/few/many ("1 podzadatak" / "2 podzadatka" / "5 podzadataka").
        // KPlural.hr carries exactly one %lld; this string also needs %@ for the joined list,
        // so the category is picked the same way KPlural does internally and formatted here
        // with both arguments (see KPlural.swift's own note on why no helper spans two kinds
        // of placeholder).
        let isCroatian = KronosLocale.languageCode == "hr"
        let pattern: String
        switch KPluralCategory.category(for: subtasks.count, isCroatian: isCroatian) {
        case .one: pattern = String(localized: "quickadd.subtasks.count.one")
        case .few: pattern = String(localized: "quickadd.subtasks.count.few")
        case .many: pattern = String(localized: "quickadd.subtasks.count.many")
        }
        return String(format: pattern, subtasks.count, subtasks.joined(separator: ", "))
    }

    /// The placeholder: the question plus one example, each example showing one token kind.
    /// Literal keys only (a key built at runtime would print raw).
    static func ghost(_ index: Int) -> String {
        switch index % 5 {
        case 0: return String(localized: "quickadd.ghost.project")
        case 1: return String(localized: "quickadd.ghost.date")
        case 2: return String(localized: "quickadd.ghost.priority")
        case 3: return String(localized: "quickadd.ghost.effort")
        default: return String(localized: "quickadd.ghost.repeat")
        }
    }

    var body: some View {
        // Read `model.version` so `@Observable` re-renders this view after a store mutation
        // made elsewhere (e.g. a project created after this view first appeared) — `parsed`
        // and `chipRow` read `model.store` directly, which the observation system does not
        // track on its own.
        let _ = model.version
        return VStack(alignment: .leading, spacing: Space.x4) {
            if let hotkeyNotice {
                Text(hotkeyNotice)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }

            EntryField(model: entry, placeholder: Self.ghost(ghostIndex),
                       selectAllOnAppear: isDraft, showSuggestions: !isTemplateLine,
                       fieldAnchor: "quickadd.field", onSubmit: submit) {
                if isDraft {
                    Text(String(localized: "quickadd.draft.caption"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .padding(.top, Space.x1)
                        .accessibilityIdentifier("quickadd.draft")
                }
            }

            if let context { QuickAddContextChips(context: context) }

            if QuickAddTemplateList.isShowing(text: entry.text, templates: TemplateStore.shared.templates) {
                // `/` prefix: the saved templates replace the legend (QuickAddTemplates.swift).
                QuickAddTemplateList(templates: TemplateStore.shared.templates, text: entry.text) { t in
                    let completed = "/" + t.name + " "
                    entry.setText(completed, caret: completed.utf16.count)
                }
            } else if legendShown {
                legend
                    .uiTestAnchor("quickadd.legend")
            } else if let subtaskSummary {
                Text(subtaskSummary)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Exactly one separator: the legend/chips block above already ends in its own
            // content with no rule of its own, so this hairline is the single dividing line
            // in the panel (an old one-line hint text plus this hairline used to read as two
            // rules stacked).
            KHairline()

            footer
        }
        .padding(Space.x5)
        .frame(width: 720)
        .background(Tok.overlay)
        .kBorder(Tok.borderControl, radius: Radius.popover)
        .clipShape(RoundedRectangle(cornerRadius: Radius.popover, style: .continuous))
        // This view's AppKit root (`NSHostingView` in `QuickAddController`, a floating
        // panel outside the window hierarchy) does not inherit the shell's environment,
        // so the colour mode is injected here and re-read every render via `model.chromaMode`.
        .environment(\.chromaMode, model.chromaMode)
        .onAppear { entry.update(catalog: EntryCatalog.make(store: model.store)) }
        .onChange(of: model.version) { _, _ in entry.update(catalog: EntryCatalog.make(store: model.store)) }
        .onChange(of: entry.text) { _, new in
            QuickAddDraft.text = new  // lets the controller keep a half-typed thought for 60 s
            if new != seedText { isDraft = false }
        }
        // Cycling placeholder: one example every few seconds while the field is empty. A timed
        // loop, so it never runs under Reduce Motion (the first example stays).
        .task {
            guard ghostCycles, !Motion.reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.ghostInterval)
                guard !Task.isCancelled else { return }
                if entry.text.isEmpty { withAnimation(Motion.hover) { ghostIndex += 1 } }
            }
        }
        .onExitCommand(perform: onClose)
    }

    private var isTemplateLine: Bool { QuickAddTemplateList.isShowing(text: entry.text, templates: TemplateStore.shared.templates) }

    /// Plain-word syntax legend: the empty-field state AND the "Show syntax" full legend are
    /// the exact same view — "Show syntax" must open the FULL legend, not a one-line hint.
    /// Every row here is verified true against `QuickAddParser`; nothing here is invented
    /// syntax.
    private var legend: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(String(localized: "quickadd.legend.title"))
                .font(Typo.hero)
                .foregroundStyle(Tok.textPrimary)
            legendRow(key: "quickadd.legend.project") { KKeyHint(String(localized: "quickadd.legend.token.project")) }
            legendRow(key: "quickadd.legend.label") { KKeyHint(String(localized: "quickadd.legend.token.label")) }
            // All four real levels (`KPriority.low...urgent`), not just the two endpoints:
            // a legend that only shows "!" and "!!!!" leaves the reader to guess whether "!!"
            // and "!!!" are valid — they are (QuickAddParserTests' `!{1,4}` grammar).
            legendRow(key: "quickadd.legend.priority") { KKeyHint("!", "!!", "!!!", "!!!!") }
            // ONE effort teaching: star count `*`/`**`/`***` = S/M/L (QuickAddParser; this view only
            // shows it). The word aliases (`*xs`..`*xl`) still parse but are not taught, so quick
            // add, Triage (S M L) and the legend agree on three sizes.
            legendRow(key: "quickadd.legend.effort") { KKeyHint("*", "**", "***") }
            // Every shape `QuickAddParser.matchDatePhrase` accepts is real vocabulary: a bare
            // weekday abbreviation, "next week", "in N days" and "25.9." all resolve.
            legendRow(key: "quickadd.legend.date") {
                KKeyHint(EntryFormat.relativeDay(Day.today(calendar: KronosLocale.calendar) + 1),
                         String(localized: "quickadd.legend.token.date.weekday"),
                         String(localized: "quickadd.legend.token.date.nextweek"),
                         String(localized: "quickadd.legend.token.date.indays"), "25.9.")
            }
            // "every week" / "svaki tjedan" (RepeatPhrase): the task repeats.
            legendRow(key: "quickadd.legend.repeat") { KKeyHint(String(localized: "quickadd.legend.token.repeat")) }
            // Subtasks: TaskOutline's own grammar — "a > b" on one line, or a Shift-Return
            // new line that starts with Tab or a bullet ("-").
            legendRow(key: "quickadd.legend.outline") { KKeyHint(">", "⇥") }
            // One line showing every token together in the order QuickAddParser reads them.
            Text(String(localized: "quickadd.legend.order_example"))
                .font(Typo.mono)
                .foregroundStyle(Tok.textTertiary)
        }
    }

    /// `minWidth` (not `width`) keeps every SHORT row tight against the same column while
    /// letting the one wide row (5 date chips) grow past it on its own.
    private func legendRow(key: String, @ViewBuilder hint: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Space.x3) {
            hint()
                .frame(minWidth: 130, alignment: .leading)
            Text(String(localized: String.LocalizationValue(key)))
                .font(Typo.rowStrong)
                .foregroundStyle(Tok.textSecondary)
            Spacer(minLength: 0)
        }
    }

    /// Key hints on the left, controls on the right; at large text sizes (or in Croatian) the
    /// controls drop to a second line instead of squeezing the hints.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.x4) {
                keyHints
                Spacer()
                controls
            }
            VStack(alignment: .leading, spacing: Space.x2) {
                keyHints
                HStack(spacing: Space.x4) {
                    Spacer()
                    controls
                }
            }
        }
    }

    private var keyHints: some View {
        HStack(spacing: Space.x4) {
            KKeyHintItem(["⏎"], label: String(localized: "quickadd.hint.add.close"))
            KKeyHintItem(["⌘", "⏎"], label: String(localized: "quickadd.hint.add.stay"))
            KKeyHintItem(["⌥", "⏎"], label: String(localized: "quickadd.hint.keep"))
            KKeyHintItem(["⇧", "⏎"], label: String(localized: "quickadd.hint.newline.short"))
        }
    }

    private var controls: some View {
        HStack(spacing: Space.x4) {
            // Off: "Mark as waiting" (ghost). On: "Waiting" with a check (filled), so the label
            // names the state it is in and nobody has to guess which side is on.
            Button {
                isWaiting.toggle()
            } label: {
                HStack(spacing: Space.x1) {
                    if isWaiting { Icon("check", size: Metrics.iconXS) }
                    Text(String(localized: isWaiting ? "status.waiting" : "quickadd.waiting.toggle"))
                }
            }
            .kButton(isWaiting ? .secondary : .ghost, size: .compact)
            .uiTestAnchor("quickadd.waiting")
            // A button, not a "?" key: a key handler on the field made "?" untypeable in a
            // title. "Show syntax" / "Hide syntax" reflects the legend and is remembered.
            Button(String(localized: legendShown ? "quickadd.legend.toggle.hide" : "quickadd.legend.toggle")) {
                legendShown.toggle()
                KronosEnv.defaults.set(legendShown, forKey: Self.legendOpenKey)
            }
            .kButton(.ghost, size: .compact)
            .uiTestAnchor("quickadd.legend.toggle")
            KKeyHintItem(["esc"], label: String(localized: "quickadd.hint.close"))
        }
    }

    /// Return chords per `QuickAddPolicy.onReturn`. Runs through the one shared
    /// `QuickAddCreate` — the same place `ListInlineNewTaskRow` calls — so quick add and every
    /// other add field understand identical text, all as one undo step.
    private func submit(_ mode: EntrySubmitMode) {
        let text = entry.text
        let key: QuickAddPolicy.ReturnKey
        switch mode {
        case .clear: key = .plain
        case .stay: key = .command
        case .keepPills: key = .option
        }
        let action = QuickAddPolicy.onReturn(key, hasText: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        switch action {
        case .close: onSubmit(); return
        case .ignore: return
        case .addAndClose, .addAndStay, .addAndKeepPills: break
        }
        // `/name rest` creates from a template (QuickAddTemplates.swift); anything else is plain text.
        switch QuickAddTemplates.submit(text: text, model: model, isWaiting: isWaiting) {
        case .created(let task): finishCreate(task, action: action); return
        case .fill(let completed): entry.setText(completed, caret: completed.utf16.count); return
        case .ignore: return
        case .notATemplate: break
        }
        guard let first = QuickAddCreate.create(from: text, model: model, isWaiting: isWaiting, pills: entry.pills,
                                                links: context?.links ?? []).first
        else { return }
        finishCreate(first, action: action)
    }

    /// After an add: the ONE acknowledgement (the shell's undo pill, QuickAddAck), then close or
    /// get ready for the next thought. Command-Return empties the field (text, pills, context
    /// chips, Waiting); Option-Return keeps the pills, the chips and the Waiting toggle. The
    /// legend's remembered choice is not reset.
    private func finishCreate(_ task: KTask, action: QuickAddPolicy.ReturnAction) {
        let keep = action == .addAndKeepPills
        entry.clear(keepingPills: keep)
        QuickAddDraft.text = ""
        if !keep {
            isWaiting = false
            context?.clear()
        }
        isDraft = false
        let defaults = KronosEnv.defaults
        defaults.set(defaults.integer(forKey: QuickAddController.addsCountKey) + 1, forKey: QuickAddController.addsCountKey)
        QuickAddAck.post(task, model: model)
        if action == .addAndClose {
            onSubmit()
        } else {
            entry.requestFocus()
        }
    }
}
