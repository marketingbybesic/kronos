// Kronos/Palette/CommandPaletteView.swift
// Cmd-K command palette. The shell presents this while model.isPaletteOpen; it flips that
// back to false to dismiss (UIContract §"transient overlays").
import SwiftUI
import KronosCore

struct CommandPaletteView: View {
    let model: AppModel
    /// Snapshot-only seeding (Kronos/Palette/PaletteSnapshots.swift): a non-empty value shows
    /// the palette already filtered, without the harness needing to simulate typing.
    private let initialQuery: String
    private let selectFirstTaskOnAppear: Bool

    @State private var query = ""
    @State private var selectedID: String?
    @State private var isShowingKeymap = false
    /// The second step of "Move to…", "Pick…" and "Rename…", shown in place of the command list.
    @State private var prompt: PalettePrompt?
    @FocusState private var isFieldFocused: Bool

    init(model: AppModel) {
        self.model = model
        self.initialQuery = ""
        self.selectFirstTaskOnAppear = false
    }

    /// Snapshot-only initializer; the frozen `init(model:)` above is what the shell calls.
    init(model: AppModel, initialQuery: String, selectFirstTask: Bool = false) {
        self.model = model
        self.initialQuery = initialQuery
        self.selectFirstTaskOnAppear = selectFirstTask
    }

    private var groups: [(group: PaletteGroup, items: [PaletteItem])] {
        PaletteResults.groups(query: query, model: model)
    }
    private var flatItems: [PaletteItem] { groups.flatMap(\.items) }

    var body: some View {
        Group {
            if let prompt {
                PalettePromptView(model: model, prompt: prompt, onBack: {
                    self.prompt = nil
                    query = ""
                    DispatchQueue.main.async { isFieldFocused = true }
                })
            } else if isShowingKeymap {
                KeymapReferenceView(onClose: { isShowingKeymap = false })
            } else {
                paletteCard
            }
        }
        .frame(maxWidth: 560)
        .uiTestAnchor("palette.card")
        .background(Tok.overlay)
        .kBorder(Tok.borderControl, radius: Radius.popover)
        .clipShape(RoundedRectangle(cornerRadius: Radius.popover, style: .continuous))
    }

    private var paletteCard: some View {
        VStack(spacing: 0) {
            field
            KHairline()
            if flatItems.isEmpty {
                emptyState
            } else {
                resultsList
            }
            KHairline()
            footer
        }
        .onAppear {
            PaletteResults.invalidate()
            if !initialQuery.isEmpty { query = initialQuery }
            selectedID = selectFirstTaskOnAppear
                ? flatItems.first { if case .task = $0 { return true }; return false }?.id ?? flatItems.first?.id
                : flatItems.first?.id
            // Not on the same turn: the field is not in the responder chain yet when onAppear
            // runs, so the focus request was lost and ⌘K typed into whatever had focus before
            // (live test 30.09.: nothing). One hop later it lands; re-asserted once more in
            // case the list's inline field re-took focus in between.
            DispatchQueue.main.async { isFieldFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isFieldFocused = true }
        }
        .onChange(of: query) { _, _ in selectedID = flatItems.first?.id }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: Space.x2) {
            Icon("search", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            TextField(String(localized: "palette.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Tok.textPrimary)
                .focused($isFieldFocused)
                .onSubmit { run(withCommandModifier: false) }
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.toolbarHeight)
        .background(PaletteKeyCatcher(onKey: handle))
    }

    // MARK: Results

    /// Tasks renders LAST (PaletteGroup's declared order) and its own row count is bounded to
    /// roughly 5 rows tall in its own inner scroll — a query with many task matches must not
    /// grow past that and push Commands/Go to below the fold; the rest of the matches are
    /// still there, reachable by scrolling that inner list.
    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.x1) {
                ForEach(groups, id: \.group) { entry in
                    sectionHeader(String(localized: String.LocalizationValue(entry.group.titleKey)))
                    if entry.group == .task {
                        taskRows(entry.items)
                    } else {
                        ForEach(entry.items) { item in
                            row(for: item)
                        }
                    }
                }
                keymapRow
            }
            .padding(.horizontal, Space.x2)
            .padding(.vertical, Space.x2)
        }
        .frame(maxHeight: 420)
    }

    /// Palette-sized group label. `KSectionHeader` is the sidebar's (20 pt above, 6 below, 28 pt
    /// tall), which stacked into ~60 pt gaps between palette groups and pushed the last group's
    /// rows below the fold, leaving a bare header at the bottom edge. Token spacing only.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Typo.caption)
            .textCase(.uppercase)
            .tracking(Tracking.caption)
            .foregroundStyle(Tok.textTertiary)
            .padding(.horizontal, Space.x2)
            .padding(.top, Space.x3)
            .padding(.bottom, Space.x1)
            .accessibilityAddTraits(.isHeader)
    }

    private func taskRows(_ items: [PaletteItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.x1) {
                ForEach(items) { item in
                    row(for: item)
                }
            }
        }
        .frame(height: min(CGFloat(items.count), 5) * Metrics.rowHeight + (min(CGFloat(items.count), 5) - 1) * Space.x1)
    }

    @ViewBuilder
    private func row(for item: PaletteItem) -> some View {
        let isSelected = item.id == selectedID
        switch item {
        case .command(let c):
            PaletteRow(isSelected: isSelected, title: c.title,
                       accessibilityLabel: ([c.title] + (c.detail.map { [$0] } ?? []) + (c.shortcut.isEmpty ? [] : [c.shortcut.joined()]))
                           .joined(separator: ", "),
                       onSelect: { selectedID = item.id; run(item, withCommandModifier: false) },
                       leading: { commandLeading(c) },
                       trailing: {
                           HStack(spacing: Space.x2) {
                               if let detail = c.detail {
                                   Text(detail).font(Typo.caption).foregroundStyle(Tok.textTertiary).lineLimit(1)
                               }
                               if !c.shortcut.isEmpty { KeyCaps(c.shortcut) }
                           }
                       })
            .id(item.id)
        case .task(let t):
            PaletteRow(isSelected: isSelected, title: t.title, accessibilityLabel: t.title,
                       onSelect: { selectedID = item.id; run(item, withCommandModifier: false) },
                       leading: { taskLeading(t) },
                       trailing: { taskTrailing(t) })
            .id(item.id)
        }
    }

    /// A Go-to project row draws that project's own identity (icon + colour); every other
    /// command keeps its registry glyph.
    @ViewBuilder
    private func commandLeading(_ c: PaletteCommand) -> some View {
        if c.projectIcon != nil || c.projectColorHex != nil {
            KProjectGlyph(icon: c.projectIcon, colorHex: c.projectColorHex, size: Metrics.iconM)
        } else {
            Icon(c.glyph, size: Metrics.iconM).foregroundStyle(Tok.textSecondary)
        }
    }

    /// Task rows use the project's own glyph/dot as the leading element, never a checkbox —
    /// in the palette, Return OPENS the task (it does not complete it), so a checkbox would
    /// signal the wrong affordance.
    @ViewBuilder
    private func taskLeading(_ t: KTask) -> some View {
        if let project = t.project {
            KProjectGlyph(icon: project.icon, colorHex: project.colorHex,
                          isFocus: t.id == model.focusTaskID, size: Metrics.iconM)
        } else {
            Icon("inbox", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
        }
    }

    @ViewBuilder
    private func taskTrailing(_ t: KTask) -> some View {
        if let day = t.dueDay {
            KDeadlineLabel(text: DeadlineFormatter.short(day: day), carryDays: t.carryDays(today: Day.today(calendar: KronosLocale.calendar)))
        }
    }

    private var keymapRow: some View {
        Button {
            isShowingKeymap = true
        } label: {
            HStack(spacing: Space.x2) {
                Icon("sliders", size: Metrics.iconM).foregroundStyle(Tok.textSecondary)
                Text("settings.tab.shortcuts").font(Typo.row).foregroundStyle(Tok.textPrimary)
                Spacer(minLength: Space.x2)
                KeyCaps(HotkeyRegistry.current(for: "window.keymap")?.displayKeys ?? [])
            }
            .padding(.horizontal, Space.x2)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering { NSCursor.pointingHand.set() } }
    }

    private var emptyState: some View {
        KEmptyState(icon: "search", title: String(localized: "palette.empty"),
                    action: query.isEmpty ? nil : KEmptyState.Action(title: String(localized: "palette.empty.clear")) { query = "" })
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.x6)
    }

    /// Decorative recap of the active keys — purely a visual aid, so it is hidden from
    /// VoiceOver (the same information is on each row's own accessibility label).
    /// Labelled per key: bare key caps read as decoration with no meaning to someone who has
    /// not memorised them. Return/Escape are drawn as the same glyphs
    /// (`HotkeyBinding.displayNames`) the Shortcuts sheet uses, not the words, so every
    /// key-hint row in the app reads as one convention.
    private var footer: some View {
        HStack(spacing: Space.x4) {
            KKeyHintItem(["↑", "↓"], label: String(localized: "palette.hint.navigate"))
            KKeyHintItem(["⏎"], label: String(localized: "palette.hint.open"))
            KKeyHintItem(["esc"], label: String(localized: "palette.hint.close"))
            Spacer()
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.controlCompact)
        .accessibilityHidden(true)
    }

    // MARK: Keyboard

    private func handle(_ event: NSEvent) -> Bool {
        switch event.specialKey {
        case .some(.upArrow):
            move(-1); return true
        case .some(.downArrow):
            move(1); return true
        default: break
        }
        // The footer row advertises Cmd-/; nothing handled it while the field had focus (audit D16).
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "/" {
            isShowingKeymap = true
            return true
        }
        if event.keyCode == 48 { // Tab
            cycleGroup(forward: !event.modifierFlags.contains(.shift))
            return true
        }
        if event.keyCode == 53 { // Esc
            if !query.isEmpty { query = ""; return true }
            model.isPaletteOpen = false
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Return
            run(withCommandModifier: event.modifierFlags.contains(.command))
            return true
        }
        return false
    }

    private func move(_ delta: Int) {
        let items = flatItems
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == selectedID } ?? 0
        let count = items.count
        let next = ((currentIndex + delta) % count + count) % count
        selectedID = items[next].id
    }

    private func cycleGroup(forward: Bool) {
        let order = groups.map(\.group)
        guard !order.isEmpty else { return }
        let currentGroup = flatItems.first { $0.id == selectedID }?.group
        let currentIndex = currentGroup.flatMap { order.firstIndex(of: $0) } ?? -1
        let count = order.count
        let nextIndex = ((currentIndex + (forward ? 1 : -1)) % count + count) % count
        selectedID = groups[nextIndex].items.first?.id
    }

    private func run(withCommandModifier keepsOpen: Bool) {
        guard let item = flatItems.first(where: { $0.id == selectedID }) else { return }
        run(item, withCommandModifier: keepsOpen)
    }

    private func run(_ item: PaletteItem, withCommandModifier keepsOpen: Bool) {
        PalettePromptCenter.shared.take()   // drop a stale request
        item.run(model)
        // A command that needs one more answer leaves a request: show its step, keep the card.
        if let next = PalettePromptCenter.shared.take() {
            prompt = next
            return
        }
        if !keepsOpen { model.isPaletteOpen = false }
    }
}

/// Relative-date text for a task row's trailing slot — mirrors the list screen's own
/// formatting approach (short, locale-aware) without depending on Kronos/List internals.
/// Uses KronosLocale, consistent with every other date display in the app.
enum DeadlineFormatter {
    static func short(day: Int) -> String { format(day: day, template: "MMMd") }

    /// "Fri 9 Oct": the date step names the weekday so a typed "fri" reads back as what it means.
    static func withWeekday(day: Int) -> String { format(day: day, template: "EEEMMMd") }

    private static func format(day: Int, template: String) -> String {
        let date = KronosCore.Day.date(day, calendar: KronosLocale.calendar)
        let formatter = DateFormatter()
        formatter.locale = KronosLocale.current
        formatter.calendar = KronosLocale.calendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// One palette row shell: leading glyph, title, trailing key hint or metadata — no checkbox.
/// `KListRow` always lays out a `KCheckbox` (correct for the task LIST, wrong here: Return
/// in the palette OPENS a task rather than completing it, and a command like "New task" has
/// no done/undone state at all), so both commands and tasks share this instead, built only
/// from `Tok`/`Space`/`Radius`/`Metrics` tokens and matching KListRow's own selection language
/// (fill + a 2pt leading bar, no focus ring — same rationale as KListRow's).
struct PaletteRow<Leading: View, Trailing: View>: View {
    let isSelected: Bool
    let title: String
    let accessibilityLabel: String
    let onSelect: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            selectionBarGutter
            Color.clear.frame(width: Metrics.listRowLeading - Metrics.sidebarSelectionBarWidth)
            leading()
            Color.clear.frame(width: Metrics.listCheckboxTitleGap)
            Text(title)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Metrics.listCheckboxTitleGap)
            trailing()
            Color.clear.frame(width: Metrics.listRowTrailing)
        }
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isSelected ? Tok.selectedFill : (isHovering ? Tok.hoverFill : .clear))
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(Motion.curve(Motion.fast), value: isHovering)
        .animation(Motion.curve(Motion.fast), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// Always-present gutter, bar as overlay — the same fix KListRow's own doc comment
    /// documents: a bare `Group { if isSelected { shape } }` collapses to zero width even
    /// inside `.frame(width:)`, which is exactly what shifted this row's icon/title ~2pt
    /// right of an unselected row's (measured: selected text started at x=90 in a 2x
    /// snapshot, unselected at x=86, before this fix).
    private var selectionBarGutter: some View {
        Color.clear
            .frame(width: Metrics.sidebarSelectionBarWidth, height: Metrics.rowHeight - Metrics.sidebarSelectionBarInset * 2)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.sidebarSelectionBarWidth / 2)
                    .fill(isSelected ? Tok.textPrimary : Color.clear)
            )
    }
}

/// `KKeyHint`'s own initializer is a fixed variadic (`String...`), which Swift cannot splat
/// from a runtime `[String]` — this wraps an arbitrary-length shortcut in the same look by
/// giving each key its own `KKeyHint` (a single key cap) inside one HStack. Outside the design
/// system every spacing value must be a token, so this uses `Space.x1` rather than matching
/// KKeyHint's own internal (DesignSystem-only) 2pt gap exactly.
struct KeyCaps: View {
    let keys: [String]
    init(_ keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: Space.x1) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KKeyHint(key)
            }
        }
    }
}

/// Installs a local NSEvent monitor scoped to this view's lifetime so arrow/Return/Esc/Tab
/// reach the palette even while the text field has first responder — SwiftUI's `.onKeyPress`
/// does not fire while a TextField owns the field editor.
struct PaletteKeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                onKey(event) ? nil : event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
