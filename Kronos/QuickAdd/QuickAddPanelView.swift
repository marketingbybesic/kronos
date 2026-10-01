// Kronos/QuickAdd/QuickAddPanelView.swift
// The panel's SwiftUI content, rebuilt larger and calmer, with a plain-word LEGEND replacing
// an old bare-symbol strip that gave no indication what each symbol meant. The legend pairs
// each real QuickAddParser token with its meaning in the UI language. It is COLLAPSED by
// default (the placeholder carries one example line, so the panel hugs its content) and the
// footer's "Show syntax" toggle opens the full legend; that choice is remembered.
// Legend and the parsed chips never show at once (spec §2.3 "rapid dump"). Parsed chips stay
// quieter than the input itself: tertiary glyphs, secondary text, no border, no fill.
//
// The field is multi-line (TaskOutline grammar: "a > b > c" on one line, or Tab-indented /
// bulleted lines under a task) so subtasks can be added from quick add too, using Tab on a
// new line, integrated so tasks and subtasks can be added quickly from anywhere in the
// interface. Submission runs through the shared `QuickAddCreate.create`, the same place
// `ListInlineNewTaskRow` already uses, so quick add and the list's inline "+" row understand
// identical text.
import SwiftUI
import AppKit
import KronosCore

struct QuickAddPanelView: View {
    let model: AppModel
    var hotkeyNotice: String?
    var seedText: String = ""
    var onSubmit: () -> Void
    var onClose: () -> Void

    @State private var text: String
    @State private var legendPinned: Bool
    // A gap this fixes: there was no Waiting control in quick add at all. Resets to off each
    // time the panel opens fresh (same as `text`/`legendPinned`): a leftover toggle from the
    // last entry silently waiting-ing the next one would be worse than retyping it.
    @State private var isWaiting: Bool
    @FocusState private var isFocused: Bool
    private let parser = QuickAddParser()

    /// True while the text is still the restored (<= 60 s) draft, untouched: it opens selected so
    /// typing replaces it, and a faint "Draft" caption says why there is text already.
    @State private var isDraft: Bool
    /// "Added: <title>" shown under the field after Return (rapid-dump flow: the panel stays open).
    @State private var addedNotice: String?
    /// UserDefaults key for the remembered "Show syntax" state (default collapsed).
    static let legendOpenKey = "kronos.quickadd.legendOpen"

    init(model: AppModel, hotkeyNotice: String? = nil, seedText: String = "", seedIsDraft: Bool = false,
         seedLegendPinned: Bool? = nil,
         seedIsWaiting: Bool = false, onSubmit: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.hotkeyNotice = hotkeyNotice
        self.seedText = seedText
        self.onSubmit = onSubmit
        self.onClose = onClose
        self._text = State(initialValue: seedText)
        self._legendPinned = State(initialValue: seedLegendPinned ?? UserDefaults.standard.bool(forKey: Self.legendOpenKey))
        self._isDraft = State(initialValue: seedIsDraft && !seedText.isEmpty)
        self._isWaiting = State(initialValue: seedIsWaiting)
    }

    /// The outline's first item: chips summarise its task-line syntax, same as before the
    /// multi-line change. Later items (more tasks, or that item's own subtasks) are covered by
    /// `subtaskSummary` below — the chip row never tries to represent more than one task.
    private var firstItem: TaskOutline.Item? { TaskOutline.parse(text).first }

    private var parsed: QuickAddParser.Parsed {
        let line = firstItem?.line ?? ""
        return parser.parse(line, projects: model.store.allProjects().map(\.name), today: Day.today(calendar: KronosLocale.calendar))
    }

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

            inputRow

            if let addedNotice, text.isEmpty {
                Text(addedNotice)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }

            if QuickAddTemplateList.isShowing(text: text, templates: TemplateStore.shared.templates) {
                // `/` prefix: the saved templates replace the legend and chips (QuickAddTemplates.swift).
                QuickAddTemplateList(templates: TemplateStore.shared.templates, text: text) { t in
                    text = "/" + t.name + " "
                }
            } else if legendPinned {
                // Only "Show syntax" opens the full legend (collapsed by default); the legend
                // and the parsed chips never show at once (spec §2.3 "rapid dump"), so
                // pinning it while typing still hides `chipRow` below.
                legend
            } else if !parsed.isEmptyResult || subtaskSummary != nil {
                VStack(alignment: .leading, spacing: Space.x2) {
                    if !parsed.isEmptyResult { chipRow }
                    if let subtaskSummary {
                        Text(subtaskSummary)
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
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
        .onAppear { DispatchQueue.main.async { isFocused = true } }
        .onChange(of: text) { _, new in
            QuickAddDraft.text = new  // lets the controller keep a half-typed thought for 60 s
            if new != seedText { isDraft = false }
            if !new.isEmpty { addedNotice = nil }
        }
        .onChange(of: legendPinned) { _, new in UserDefaults.standard.set(new, forKey: Self.legendOpenKey) }
        .onExitCommand(perform: onClose)
        .animation(Motion.hover, value: text.isEmpty)
    }

    /// The input itself, built larger than `KTextField`'s fixed control height so it reads
    /// as the hero of a calmer, more generous panel — same tokens (`Typo.title`, `Tok`,
    /// `Space`, `Radius`) the design system's own controls are built from, just a bigger
    /// composition of them for this one field. Multi-line, so subtasks can be entered with
    /// Tab on a new line: a plain `TextField` cannot hold more than one line, so this is a
    /// `TextEditor` — its backing `NSTextView` is a real multi-line editor (not a single-line
    /// field editor), so Tab already inserts a literal tab character with no extra code,
    /// which is exactly what `TaskOutline.dissect` reads as one level of indent. Only Return
    /// needs custom handling: plain Return submits (`QuickAddKeyCatcher` below), Option/Shift-
    /// Return fall through to `TextEditor`'s own default and insert a newline.
    private var inputRow: some View {
        HStack(alignment: .top, spacing: Space.x3) {
            Icon("plus", size: Metrics.iconL)
                .foregroundStyle(Tok.textTertiary)
                .padding(.top, Space.x1)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(String(localized: "quickadd.placeholder"))
                        .font(Typo.title)
                        // Tertiary, not `textDisabled`: this placeholder is an active
                        // invitation to type, not a disabled control.
                        .foregroundStyle(Tok.textTertiary)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(Typo.title)
                    .foregroundStyle(Tok.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    // No horizontal/vertical padding of its own beyond TextEditor's built-in
                    // inset, so a one-line entry lines up with the old TextField exactly.
                    .padding(.horizontal, -Space.x1)
                    .background(QuickAddKeyCatcher(onReturn: submit, selectAllOnAppear: isDraft))
                    .uiTestAnchor("quickadd.field")
            }
            if isDraft {
                Text(String(localized: "quickadd.draft.caption"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .padding(.top, Space.x1)
                    .accessibilityIdentifier("quickadd.draft")
            }
        }
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        // No max height — the box grows with every line, same as the legend already does. A
        // capped height needs an internal scroll view, and a `TextEditor` scrolled to the caret
        // mid-outline clips its last line with no fade, which reads as broken. Fine for a
        // quick-add outline (a handful of subtasks); revisit with a scroll + top/bottom fade
        // mask if someone pastes a genuinely long list in here.
        .frame(minHeight: Metrics.controlRegular + Space.x4)
        .fixedSize(horizontal: false, vertical: true)
        .background(isFocused ? Tok.bg : Tok.controlFill)
        .kBorder(isFocused ? Tok.borderActive : Color.clear, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .animation(Motion.hover, value: isFocused)
    }

    /// Plain-word syntax legend: the empty-field state AND the "Show syntax" full legend are
    /// the exact same view — "Show syntax" must open the FULL legend, not a one-line hint.
    /// Every row here is verified true against `QuickAddParser`; nothing here is invented
    /// syntax. Never shown together with the parsed chips (spec §2.3 "rapid dump").
    private var legend: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(String(localized: "quickadd.legend.title"))
                .font(Typo.hero)
                .foregroundStyle(Tok.textPrimary)
            // REVIEW FIX: dropped the duplicate one-token example line that used to sit here —
            // `quickadd.legend.order_example` at the bottom already shows a real line with every
            // token in order, which is strictly more useful than a second, shorter example above it.
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
            // Used to be one dynamic "Tomorrow" chip. Every shape `QuickAddParser
            // .matchDatePhrase` actually accepts is real vocabulary, not just the relative-day
            // word: a bare weekday abbreviation, "next week", and "in N days" all resolve too
            // (see QuickAddParserTests.QuickAddNaturalDateTests), and the legend claiming only
            // "tomorrow" undersold what typing a date here can do.
            legendRow(key: "quickadd.legend.date") {
                KKeyHint(relativeDay(Day.today(calendar: KronosLocale.calendar) + 1),
                         String(localized: "quickadd.legend.token.date.weekday"),
                         String(localized: "quickadd.legend.token.date.nextweek"),
                         String(localized: "quickadd.legend.token.date.indays"), "25.9.")
            }
            // Subtasks: TaskOutline's own grammar — "a > b" on one line, or an Option/Shift-Return
            // new line that starts with Tab or a bullet ("-"). `>` here is the real separator
            // `TaskOutline.split` matches (it needs a space on both sides).
            legendRow(key: "quickadd.legend.outline") { KKeyHint(">", "⇥") }
            // One line showing every token together in the order QuickAddParser actually
            // reads them, so the legend answers "what order do I type these in" without the
            // reader assembling it from the rows above. Monospace, like the existing
            // one-token example above.
            Text(String(localized: "quickadd.legend.order_example"))
                .font(Typo.mono)
                .foregroundStyle(Tok.textTertiary)
        }
    }

    /// REVIEW FIX: was a hard `.frame(width: 210)`, sized for the shortest rows — that left
    /// ~440px of dead air after the priority row's lone "!" chip. `minWidth` (not `width`) keeps
    /// every SHORT row tight against the same 130pt column while letting the one genuinely wide
    /// row (5 date chips: tomorrow/weekday/next week/in N days/25.9.) grow past it on its own —
    /// a custom `HorizontalAlignment` guide was tried first and rejected: aligning every row's
    /// TRAILING edge to the widest one forces the whole VStack wider than its own 720pt `.frame`
    /// to satisfy that alignment, which pushed the card's LEFT edge off-screen (caught by
    /// re-shooting and reading the snapshot — exactly what "re-shoot + READ" is for).
    private func legendRow(key: String, @ViewBuilder hint: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Space.x3) {
            hint()
                .frame(minWidth: 130, alignment: .leading)
            // The explanation is the actual content of a legend row, not a caption about it
            // (art-direction's tonal-hierarchy rule: "nothing decorative may be primary" cuts
            // the other way too — a row's one useful line is secondary, not tertiary).
            Text(String(localized: String.LocalizationValue(key)))
                .font(Typo.rowStrong)
                .foregroundStyle(Tok.textSecondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var chipRow: some View {
        HStack(spacing: Space.x2) {
            if let projectName = parsed.projectName {
                let project = model.store.allProjects().first { $0.name == projectName }
                KChip(String(format: String(localized: "quickadd.chip.project"), projectName)) {
                    KProjectGlyph(icon: project?.icon, colorHex: project?.colorHex, size: Metrics.iconS)
                }
            } else if let unresolved = parsed.unresolvedProjectToken {
                let name = String(unresolved.dropFirst()).replacingOccurrences(of: "-", with: " ")
                // This chip used to be inert. Clicking it now creates that project for real
                // (same bare-name creation other screens in this app already use, e.g. MenuBarSnapshots)
                // and rewrites the raw text's `#token` through the pure `QuickAddParser
                // .rewriteProjectToken`, so re-parsing resolves it and the chip becomes the normal
                // resolved-project chip above.
                KChip(String(format: String(localized: "quickadd.chip.noproject.name"), name), onTap: {
                    _ = model.store.createProject(name: name)
                    model.didMutate()
                    text = QuickAddParser.rewriteProjectToken(in: text, unresolvedToken: unresolved,
                                                              resolvedProjectName: name)
                }) {
                    Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                }
            }
            if let labelName = parsed.labelName {
                KChip(String(format: String(localized: "quickadd.chip.label"), labelName))
            }
            if parsed.priority != .none {
                KChip(String(format: String(localized: "quickadd.chip.priority"), priorityName(parsed.priority))) {
                    KPriorityIndicator(level: parsed.priority.rawValue, label: priorityName(parsed.priority), size: Metrics.iconS)
                }
            }
            if let effort = parsed.effort, effort != .none {
                KChip(String(format: String(localized: "quickadd.chip.effort.value"), effortName(effort))) {
                    KEffortIndicator(level: effort.rawValue, of: KEffort.allCases.count - 1, label: nil, showLabel: false)
                }
            }
            if let dueDay = parsed.dueDay {
                KChip(String(format: String(localized: "quickadd.chip.due"), relativeDay(dueDay))) {
                    Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.x4) {
            KKeyHintItem(["⏎"], label: String(localized: "quickadd.hint.return"))
            KKeyHintItem(["⌥", "⏎"], label: String(localized: "quickadd.hint.newline.short"))
            Spacer()
            // A real Waiting toggle, previously missing entirely. Filled (`.secondary`) when
            // on so it reads as a pressed state, quiet ghost when off; wins the status over
            // every scope (ListScopeDefaultsTests.waitingToggleAlwaysWinsOverEveryScope).
            // Off: "Mark as waiting" (ghost). On: "Waiting" with a check (filled), so the label
            // names the state it is in and nobody has to guess which side is on (audit D1).
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
            // title. Always present (the legend is collapsed by default): "Show syntax" /
            // "Hide syntax" reflects `legendPinned`, which is remembered across opens.
            Button(String(localized: legendPinned ? "quickadd.legend.toggle.hide" : "quickadd.legend.toggle")) {
                legendPinned.toggle()
            }
            .kButton(.ghost, size: .compact)
            .uiTestAnchor("quickadd.legend.toggle")
            KKeyHintItem(["⎋"], label: String(localized: "quickadd.hint.close"))
        }
    }

    /// Today / Tomorrow / weekday name / "20 Sep" — `KDeadlineLabel`'s doc says relative-date
    /// logic lives outside DesignSystem, so each caller formats its own. "Today" reuses the
    /// app's own catalog key; "Tomorrow" and weekday names come from `RelativeDateTimeFormatter`
    /// / `DateFormatter`, both built with `KronosLocale.current` (the APP language, e.g. HR
    /// "Sutra" regardless of the system locale) — never `Locale.current`.
    private func relativeDay(_ day: Int) -> String {
        let calendar = KronosLocale.calendar
        let today = Day.today(calendar: calendar)
        let date = Day.date(day, calendar: calendar)
        if day == today { return String(localized: "list.filter.due.today") }
        if day == today + 1 {
            let formatter = RelativeDateTimeFormatter()
            formatter.calendar = calendar
            formatter.locale = KronosLocale.current
            formatter.dateTimeStyle = .named
            formatter.formattingContext = .beginningOfSentence
            return formatter.localizedString(for: date, relativeTo: Day.date(today, calendar: calendar))
        }
        if day > today, day - today < 7 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = KronosLocale.current
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = KronosLocale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    private func priorityName(_ p: KPriority) -> String {
        switch p {
        case .none: return String(localized: "priority.none")
        case .low: return String(localized: "priority.low")
        case .medium: return String(localized: "priority.medium")
        case .high: return String(localized: "priority.high")
        case .urgent: return String(localized: "priority.urgent")
        }
    }

    private func effortName(_ e: KEffort) -> String {
        switch e {
        case .none: return String(localized: "effort.none")
        case .xs: return String(localized: "effort.xs")
        case .s: return String(localized: "effort.s")
        case .m: return String(localized: "effort.m")
        case .l: return String(localized: "effort.l")
        case .xl: return String(localized: "effort.xl")
        }
    }

    /// §4.1.6: empty title -> Return does nothing. Runs through the one shared
    /// `QuickAddCreate` (Kronos/Shared/QuickAddCreate.swift) — the same place
    /// `ListInlineNewTaskRow` calls — instead of this view creating tasks itself, so quick add
    /// and every other add field understand identical text (project/label/priority/effort/date
    /// per task line via QuickAddParser, plus "a > b" / Tab / bulleted subtasks via TaskOutline,
    /// all as one undo step).
    private func submit() {
        // `/name rest` creates from a template (QuickAddTemplates.swift); anything else is plain text.
        switch QuickAddTemplates.submit(text: text, model: model, isWaiting: isWaiting) {
        case .created:
            finishCreate(String(text.dropFirst()).trimmingCharacters(in: .whitespaces)); return
        case .fill(let completed): text = completed; return
        case .ignore: return
        case .notATemplate: break
        }
        guard let first = QuickAddCreate.create(from: text, model: model, isWaiting: isWaiting).first else { return }
        finishCreate(first.title)
    }

    /// One consistent create path: clear the field (nothing is restored as a draft), post the
    /// shell's undo pill (the whole entry is one undo step) and STAY OPEN with focus in the empty
    /// field for the next thought (rapid dump). Esc closes. The legend choice is a remembered
    /// preference and is not reset.
    private func finishCreate(_ title: String) {
        text = ""
        QuickAddDraft.text = ""
        isWaiting = false
        isDraft = false
        let notice = String(format: String(localized: "quickadd.created"), title)
        addedNotice = notice
        UndoToastCenter.shared.show(notice)
        DispatchQueue.main.async { isFocused = true }
    }
}

private extension QuickAddParser.Parsed {
    var isEmptyResult: Bool {
        projectName == nil && labelName == nil && priority == .none && dueDay == nil
            && unresolvedProjectToken == nil && effort == nil
    }
}
