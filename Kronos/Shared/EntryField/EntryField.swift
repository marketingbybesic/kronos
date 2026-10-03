// Kronos/Shared/EntryField/EntryField.swift
// The entry field: a multi-line text field, the pills of everything already resolved (project
// or area, label, priority, effort, date), and a suggestion list under the field while a
// token is being typed. One component for every surface that adds tasks; the global quick add
// panel is the first user. It owns no store access: it reads and writes an `EntryFieldModel`.
//
// Keys (EntryKeyBridge, one monitor, active only while this field's text view has focus):
//   Up/Down  move in the list            Tab   take the highlighted suggestion
//   Return   take it when a `#`/`@` name is incomplete, otherwise submit (clears all)
//   Command-Return  submit and keep going (the quick add panel stays open; elsewhere = Return)
//   Option-Return  submit, keep the pills     Shift-Return  new line
//   Esc      closes the list first (then the host closes itself)
//   Backspace in an empty field removes the last pill; clicking a pill lists alternatives.
import SwiftUI
import AppKit
import KronosCore

struct EntryField<Trailing: View>: View {
    /// `.panel`: the big boxed field of the quick add panel. `.row`: one list row high, no box,
    /// in the row font, for an inline add row that carries its own leading control.
    enum Style { case panel, row }

    @Bindable var model: EntryFieldModel
    var placeholder: String
    /// A restored draft opens fully selected.
    var selectAllOnAppear = false
    /// The host passes false while it shows its own list for the same text (the `/` templates).
    var showSuggestions = true
    var fieldAnchor = "entry.field"
    /// False for a field that sits in a screen that already has keyboard focus (a list row, the
    /// inspector): it takes focus when clicked or asked (`requestFocus`), not on appearing.
    var autofocus = true
    var style: Style = .panel
    /// `.row` only: a control left of the input (the add button). Pills and list line up with the input.
    var rowLeading: (() -> AnyView)?
    var onSubmit: (EntrySubmitMode) -> Void
    @ViewBuilder var trailing: () -> Trailing

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            if style == .row { rowInput } else { inputRow }
            Group {
                EntryPillsRow(model: model)
                if showSuggestions, !model.isTemplateLine, model.isListOpen {
                    EntrySuggestionList(model: model)
                }
            }
            .padding(.leading, style == .row ? Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap : 0)
        }
        .onAppear { if autofocus { DispatchQueue.main.async { isFocused = true } } }
        .onChange(of: model.focusToken) { _, _ in DispatchQueue.main.async { isFocused = true } }
    }

    /// The inline-row flavour of the same editor: row font, no box, one row tall, growing with
    /// every line. Same TextEditor, key bridge and anchor as the panel's field.
    private var rowInput: some View {
        HStack(alignment: .center, spacing: 0) {
            if let rowLeading {
                rowLeading()
                Color.clear.frame(width: Metrics.listCheckboxTitleGap)
            }
            // `.leading` (vertically centred) with an editor only as tall as its text: the
            // placeholder, the typed first line and the leading + share one centre line in the
            // row. A top-aligned stack inside a row-tall editor left the + about 10 pt below
            // the text.
            ZStack(alignment: .leading) {
                if model.text.isEmpty {
                    Text(placeholder)
                        .font(Typo.row)
                        .foregroundStyle(Tok.textTertiary)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, -Space.x1)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(EntryKeyBridge(model: model, selectAllOnAppear: selectAllOnAppear, onSubmit: onSubmit))
                    .accessibilityLabel(String(localized: "quickadd.entry.a11y.field"))
                    .uiTestAnchor(fieldAnchor)
            }
            trailing()
        }
        .frame(minHeight: Metrics.rowHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Built larger than `KTextField`'s fixed control height so the input reads as the hero of
    /// a calm panel. A `TextEditor` (its NSTextView is a real multi-line editor) so Tab can
    /// indent a subtask line and Shift-Return can start one.
    private var inputRow: some View {
        HStack(alignment: .top, spacing: Space.x3) {
            Icon("plus", size: Metrics.iconL)
                .foregroundStyle(Tok.textTertiary)
                .padding(.top, Space.x1)
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text(placeholder)
                        .font(Typo.title)
                        .foregroundStyle(Tok.textTertiary)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .font(Typo.title)
                    .foregroundStyle(Tok.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, -Space.x1)
                    .background(EntryKeyBridge(model: model, selectAllOnAppear: selectAllOnAppear, onSubmit: onSubmit))
                    .accessibilityLabel(String(localized: "quickadd.entry.a11y.field"))
                    .uiTestAnchor(fieldAnchor)
            }
            trailing()
        }
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x3)
        // No max height: the box grows with every line, like the legend does. A capped height
        // needs an inner scroll view, and a TextEditor scrolled mid-outline clips its last line.
        .frame(minHeight: Metrics.controlRegular + Space.x4)
        .fixedSize(horizontal: false, vertical: true)
        .background(isFocused ? Tok.bg : Tok.controlFill)
        .kBorder(isFocused ? Tok.borderActive : Color.clear, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .animation(Motion.hover, value: isFocused)
    }
}

extension EntryField where Trailing == EmptyView {
    init(model: EntryFieldModel, placeholder: String, selectAllOnAppear: Bool = false, showSuggestions: Bool = true,
         fieldAnchor: String = "entry.field", autofocus: Bool = true, style: Style = .panel,
         rowLeading: (() -> AnyView)? = nil, onSubmit: @escaping (EntrySubmitMode) -> Void) {
        self.init(model: model, placeholder: placeholder, selectAllOnAppear: selectAllOnAppear,
                  showSuggestions: showSuggestions, fieldAnchor: fieldAnchor, autofocus: autofocus, style: style,
                  rowLeading: rowLeading,
                  onSubmit: onSubmit) { EmptyView() }
    }
}

// MARK: - Pills

/// One KChip per resolved attribute, in slot order, wrapping onto more lines at large text
/// sizes. The chip itself changes the pill (click lists the alternatives); its ✕ removes it.
struct EntryPillsRow: View {
    let model: EntryFieldModel

    var body: some View {
        let resolved = model.resolved
        if !resolved.chips.isEmpty || resolved.unresolvedDestination != nil {
            KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
                ForEach(resolved.chips, id: \.pill.slot) { chip in
                    let slot = Self.anchorName(chip.pill.slot)
                    KChip(EntryFormat.pillText(chip.pill), trailing: .clear,
                          onTap: { model.openSlotMenu(chip) },
                          onTrailingTap: { model.remove(chip) },
                          trailingAnchorID: "entry.pill.\(slot).remove") { glyph(chip.pill) }
                        .frame(maxWidth: 520, alignment: .leading)
                        .help(String(format: String(localized: "quickadd.entry.pill.change"), EntryFormat.slotName(chip.pill.slot)))
                        .uiTestAnchor("entry.pill.\(slot)")
                }
                if let u = resolved.unresolvedDestination, model.kind == .child {
                    // A subtask lives where its parent lives: the typed project is ignored and
                    // stays in the title; the x takes it out of the text.
                    KChip(u.text, trailing: .clear, onTap: {}, onTrailingTap: { model.removeIgnoredDestination() },
                          trailingAnchorID: "entry.pill.ignored.remove") {
                        Icon("slash.circle", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .help(String(format: String(localized: "quickadd.entry.pill.ignored"), u.text))
                    .uiTestAnchor("entry.pill.ignored")
                } else if let u = resolved.unresolvedDestination {
                    KChip(String(format: String(localized: "quickadd.entry.suggest.create.project"), u.name),
                          onTap: { model.commitUnresolved() }) {
                        Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .uiTestAnchor("entry.pill.create")
                }
            }
            .animation(Motion.hover, value: resolved.chips.map(\.pill))
        }
    }

    static func anchorName(_ slot: EntryPill.Slot) -> String {
        switch slot {
        case .destination: return "destination"
        case .label: return "label"
        case .priority: return "priority"
        case .effort: return "effort"
        case .due: return "due"
        case .repeats: return "repeat"
        }
    }

    @ViewBuilder private func glyph(_ pill: EntryPill) -> some View {
        switch pill {
        case .destination(let d):
            if d.isNew {
                Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            } else {
                let g = model.catalog.glyph(for: d)
                KProjectGlyph(icon: d.kind == .project ? g?.icon : nil, colorHex: g?.colorHex, size: Metrics.iconS)
            }
        case .label:
            Icon("tag", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
        case .priority(let p):
            KPriorityIndicator(level: p.rawValue, label: EntryFormat.priorityName(p), size: Metrics.iconS)
        case .effort(let e):
            KEffortIndicator(level: e.rawValue, of: KEffort.allCases.count - 1, label: nil, showLabel: false)
        case .due:
            Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
        case .repeats:
            Icon("repeat", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
        }
    }
}

// MARK: - Suggestions

/// The list under the field. Styled like the `/` template list (QuickAddTemplateList): one
/// quiet row per item, the highlighted row carries its key hint, nothing floats over other
/// content, so the panel simply grows to fit.
struct EntrySuggestionList: View {
    let model: EntryFieldModel

    var body: some View {
        let v = model.visible
        VStack(alignment: .leading, spacing: Space.x1) {
            ForEach(Array(v.items.enumerated()), id: \.element.id) { index, s in
                row(s, index: index, selected: index == model.selection)
            }
            hints(slotMenu: v.isSlotMenu)
                .padding(.top, Space.x1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "quickadd.entry.a11y.list"))
        .uiTestAnchor("entry.list")
    }

    private func hints(slotMenu: Bool) -> some View {
        HStack(spacing: Space.x4) {
            KKeyHintItem(["↑", "↓"], label: String(localized: "quickadd.entry.hint.choose"))
            KKeyHintItem(["⇥"], label: String(localized: "quickadd.entry.hint.accept"))
            KKeyHintItem(["esc"], label: String(localized: "quickadd.entry.hint.closelist"))
            Spacer(minLength: 0)
        }
    }

    private func row(_ s: EntrySuggestion, index: Int, selected: Bool) -> some View {
        Button { model.accept(s) } label: {
            HStack(spacing: Space.x2) {
                glyph(s)
                content(s, selected: selected)
                Spacer(minLength: 0)
                if selected { KKeyHint(model.returnAccepts ? "⏎" : "⇥") }
            }
            .padding(.horizontal, Space.x2)
            // Frame + contentShape INSIDE the label: a plain-style button is pressable only on
            // its opaque label pixels.
            .frame(height: Metrics.minHit + Space.x1, alignment: .leading)
            .background(selected ? Tok.hoverFill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { model.select(index) } }
        .accessibilityLabel(Self.spoken(s))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .uiTestAnchor("entry.row.\(index)")
    }

    @ViewBuilder private func glyph(_ s: EntrySuggestion) -> some View {
        switch s.pill {
        case .destination(let d):
            if s.isCreate {
                Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            } else {
                let g = model.catalog.glyph(for: d)
                KProjectGlyph(icon: d.kind == .project ? g?.icon : nil, colorHex: g?.colorHex, size: Metrics.iconS)
            }
        case .label(let n):
            Icon(s.isCreate ? "plus" : "tag", size: Metrics.iconS).foregroundStyle(Tok.textTertiary).help(n)
        case .priority(let p):
            KPriorityIndicator(level: p.rawValue, label: EntryFormat.priorityName(p), size: Metrics.iconS)
        case .effort(let e):
            KEffortIndicator(level: e.rawValue, of: KEffort.allCases.count - 1, label: nil, showLabel: false)
        case .due:
            Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
        case .repeats:
            Icon("repeat", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
        }
    }

    @ViewBuilder private func content(_ s: EntrySuggestion, selected: Bool) -> some View {
        let primary: Color = selected ? Tok.textPrimary : Tok.textSecondary
        switch s.pill {
        case .destination(let d):
            if s.isCreate {
                Text(String(format: String(localized: "quickadd.entry.suggest.create.project"), d.name))
                    .font(Typo.rowStrong).foregroundStyle(primary).lineLimit(1)
            } else {
                Text(d.name).font(Typo.rowStrong).foregroundStyle(primary).lineLimit(1)
                Text(String(localized: d.kind == .project ? "quickadd.entry.kind.project" : "quickadd.entry.kind.area"))
                    .font(Typo.meta).foregroundStyle(Tok.textTertiary).lineLimit(1)
            }
        case .label(let n):
            Text(s.isCreate ? String(format: String(localized: "quickadd.entry.suggest.create.label"), n) : n)
                .font(Typo.rowStrong).foregroundStyle(primary).lineLimit(1)
        case .priority(let p):
            Text(EntryFormat.priorityName(p)).font(Typo.rowStrong).foregroundStyle(primary).lineLimit(1)
            Text(String(repeating: "!", count: p.rawValue)).font(Typo.mono).foregroundStyle(Tok.textTertiary)
        case .effort(let e):
            Text(EntryFormat.effortName(e)).font(Typo.rowStrong).foregroundStyle(primary).lineLimit(1)
        case .due(let day):
            // "Tomorrow" / "Wednesday" with the date after it; past a week the relative name IS
            // the date, so the phrase the person typed ("next week") takes the first place.
            let date = EntryFormat.shortDate(day)
            let relative = EntryFormat.relativeDay(day)
            Text(relative == date ? s.title : relative).font(Typo.rowStrong).foregroundStyle(primary).lineLimit(1)
            Text(date).font(Typo.meta).foregroundStyle(Tok.textTertiary).lineLimit(1)
        case .repeats(let r):
            Text(EntryFormat.repeatName(r)).font(Typo.rowStrong).foregroundStyle(primary).lineLimit(1)
        }
    }

    /// What VoiceOver reads for a row.
    static func spoken(_ s: EntrySuggestion) -> String {
        switch s.pill {
        case .destination(let d):
            if s.isCreate { return String(format: String(localized: "quickadd.entry.suggest.create.project"), d.name) }
            return d.name + ", " + String(localized: d.kind == .project ? "quickadd.entry.kind.project" : "quickadd.entry.kind.area")
        case .label(let n):
            return s.isCreate ? String(format: String(localized: "quickadd.entry.suggest.create.label"), n) : n
        case .priority(let p): return EntryFormat.priorityName(p)
        case .effort(let e): return EntryFormat.effortName(e)
        case .due(let day): return EntryFormat.relativeDay(day) + ", " + EntryFormat.shortDate(day)
        case .repeats(let r): return EntryFormat.repeatName(r)
        }
    }
}
