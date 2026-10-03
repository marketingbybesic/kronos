// Kronos/Shared/EntryField/EntryFieldModel.swift
// State and actions of one entry field: the text, the pills the user committed, the caret, and
// the suggestion list derived from them by Core (`EntrySuggester`, `EntryDraft`). The view
// (EntryField) and the key handling (EntryKeyBridge) only call this; nothing here knows about
// layout. Any surface that wants "text + pills + autocomplete" owns one of these.
import SwiftUI
import AppKit
import KronosCore

@MainActor
@Observable
final class EntryFieldModel {

    /// What the list under the field shows right now.
    struct Visible {
        var items: [EntrySuggestion]
        var active: EntryActiveToken?
        /// A menu opened from a pill, not by typing.
        var isSlotMenu: Bool

        static let none = Visible(items: [], active: nil, isSlotMenu: false)
    }

    /// The text, bound to the field. Any change closes a pill menu and restarts the selection.
    var text: String {
        didSet { if text != oldValue { slotMenu = nil; selectedIndex = 0 } }
    }
    /// Pills the user committed (accepted suggestions, a prefilled destination). A token still
    /// typed in the text overrides the pill of its slot (`EntryDraft.resolve`).
    var pills: [EntryPill]
    private(set) var caret = 0
    private(set) var hasSelection = false
    /// Highlighted row of the list.
    private(set) var selectedIndex = 0
    /// The pill whose change menu is open, if any.
    private(set) var slotMenu: EntryPill.Slot?

    private(set) var catalog: EntryCatalog
    /// Bumped to ask the field to take keyboard focus again (after an add).
    private(set) var focusToken = 0
    /// Rows shown at most (a create row may come on top of them).
    static let listLimit = 6

    /// What the field adds. A `.child` entry (a subtask) takes every token of a task line
    /// except a project or area: a child lives where its parent lives, so `#` offers nothing,
    /// a typed `#word` stays literal text, and `>` / indentation make no structure.
    enum Kind { case task, child }
    let kind: Kind

    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored private var slotMenuReplace: Range<Int>?
    @ObservationIgnored private var dismissedKey: String?
    @ObservationIgnored private var catalogVersion = 0
    /// Injectable for tests and snapshots.
    @ObservationIgnored var today: () -> Int = { Day.today(calendar: KronosLocale.calendar) }
    @ObservationIgnored var languages = QuickAddParser.defaultLanguages
    @ObservationIgnored private var cache: (key: String, resolved: EntryResolved, visible: Visible)?

    init(text: String = "", pills: [EntryPill] = [], catalog: EntryCatalog = .empty, kind: Kind = .task) {
        self.kind = kind
        self.text = text
        self.pills = pills
        self.catalog = catalog
        self.caret = text.utf16.count
    }

    func update(catalog: EntryCatalog) {
        self.catalog = catalog
        catalogVersion += 1
    }

    // MARK: Derived

    private func derive() -> (resolved: EntryResolved, visible: Visible) {
        let key = "\(catalogVersion)|\(caret)|\(hasSelection)|\(slotMenu.map { String($0.rawValue) } ?? "-")|\(dismissedKey ?? "-")|\(pills.hashValue)|\(text)"
        if let cache, cache.key == key { return (cache.resolved, cache.visible) }
        let day = today()
        let line = kind == .child ? (ChildEntry.lines(text).first ?? "") : (TaskOutline.parse(text).first?.line ?? "")
        let offset = line.isEmpty ? 0 : (text.range(of: line).map { text.utf16.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0)
        let resolved = kind == .child
            ? ChildEntry.resolve(line: line, pills: pills, directory: catalog.directory, today: day,
                                 languages: languages, lineOffset: offset)
            : EntryDraft.resolve(text: line, pills: pills, directory: catalog.directory, today: day,
                                 languages: languages, lineOffset: offset, readsRepeat: true)
        var visible = Visible.none
        if let slot = slotMenu {
            let items = EntrySuggester.suggestions(for: slot, directory: catalog.directory, today: day, languages: languages, limit: Self.listLimit)
            visible = Visible(items: items.map { var s = $0; if let r = slotMenuReplace { s.replaceRange = r }; return s },
                              active: nil, isSlotMenu: true)
        } else if !hasSelection {
            let s = EntrySuggester.suggest(text: text, caret: caret, directory: catalog.directory, today: day, languages: languages, limit: Self.listLimit)
            let items = kind == .child ? s.items.filter { ChildEntry.allows($0.pill) } : s.items
            if let a = s.active, a.sigil != .template, !items.isEmpty, dismissedKey != Self.dismissKey(a) {
                visible = Visible(items: items, active: a, isSlotMenu: false)
            }
        }
        cache = (key, resolved, visible)
        return (resolved, visible)
    }

    private static func dismissKey(_ a: EntryActiveToken) -> String { "\(a.sigil)|\(a.range.lowerBound)" }

    /// The first outline line merged with the committed pills: what the pills row shows and
    /// what the first created task gets.
    var resolved: EntryResolved { derive().resolved }
    var visible: Visible { derive().visible }
    var isListOpen: Bool { !visible.items.isEmpty }
    var isTemplateLine: Bool { TemplateQuery.isTemplateInput(text) }

    var selection: Int { min(selectedIndex, max(0, visible.items.count - 1)) }
    var selected: EntrySuggestion? {
        let items = visible.items
        return items.isEmpty ? nil : items[selection]
    }

    /// Whether plain Return takes the highlighted suggestion (true) or submits the entry. A
    /// typed `#`/`@` name that is not complete yet is taken; a complete name, a create row, `!`,
    /// `*` and date words submit as typed (Tab takes them): "Call Tom" must not turn into
    /// "tomorrow", and "Fix #123" must not turn into a new project.
    var returnAccepts: Bool {
        let v = visible
        guard let s = selected else { return false }
        if v.isSlotMenu { return true }
        guard let a = v.active, a.sigil == .destination || a.sigil == .label else { return false }
        // Never a create row: "Fix #parser" + Return must stay a plain add; Tab or a click creates.
        if s.isCreate { return false }
        func key(_ s: String) -> String { KTextFold.fold(s.replacingOccurrences(of: "-", with: " ")) }
        return key(a.query) != key(s.title)
    }

    // MARK: Caret and list navigation

    /// Not clamped to the text length here: AppKit reports the new selection a moment before the
    /// binding delivers the new text, and clamping against the old text would lose the caret.
    /// Core clamps it where it is used.
    func setCaret(_ location: Int, hasSelection: Bool) {
        let c = max(location, 0)
        if c != caret || hasSelection != self.hasSelection { selectedIndex = 0 }
        caret = c
        self.hasSelection = hasSelection
    }

    func select(_ index: Int) {
        if index != selectedIndex { selectedIndex = index }
    }

    func requestFocus() { focusToken += 1 }

    /// Puts the caret in the field through AppKit when its text view is attached (SwiftUI's
    /// FocusState request can be dropped while the window is still becoming key), else asks
    /// SwiftUI. A field that already has the caret is left alone.
    func focusTextView() {
        if let tv = textView, let window = tv.window {
            if window.firstResponder !== tv { window.makeFirstResponder(tv) }
        } else {
            requestFocus()
        }
    }

    func move(_ delta: Int) {
        let n = visible.items.count
        guard n > 0 else { return }
        selectedIndex = (selection + delta + n) % n
    }

    /// Esc: closes the pill menu or the typed list. Returns false when there was nothing to
    /// close, so the caller lets Esc close the panel.
    @discardableResult
    func closeList() -> Bool {
        if slotMenu != nil { slotMenu = nil; slotMenuReplace = nil; return true }
        if let a = visible.active { dismissedKey = Self.dismissKey(a); selectedIndex = 0; return true }
        return false
    }

    // MARK: Accepting and removing

    func acceptSelected() {
        if let s = selected { accept(s) }
    }

    func accept(_ suggestion: EntrySuggestion) {
        slotMenu = nil
        slotMenuReplace = nil
        dismissedKey = nil
        if !suggestion.replaceRange.isEmpty { cut(suggestion.replaceRange) }
        pills = EntryDraft.setting(suggestion.pill, in: pills)
        refocus()
    }

    /// × on a pill. A token still in the text goes out of the text; a committed pill of the
    /// same slot goes too, so the pill really disappears.
    func remove(_ chip: EntryChip) {
        if case .typed(let range) = chip.source { cut(range) }
        pills.removeAll { $0.slot == chip.pill.slot }
        slotMenu = nil
        refocus()
    }

    /// × on the ignored `#word` pill of a child entry: the token leaves the text.
    func removeIgnoredDestination() {
        guard let u = resolved.unresolvedDestination else { return }
        cut(u.range)
        refocus()
    }

    /// ⌫ in an empty field. False when there was no pill to remove.
    @discardableResult
    func removeLastPill() -> Bool {
        guard let last = resolved.chips.last else { return false }
        remove(last)
        return true
    }

    /// Click on a pill: the list of alternatives for its slot.
    func openSlotMenu(_ chip: EntryChip) {
        slotMenu = chip.pill.slot
        if case .typed(let r) = chip.source { slotMenuReplace = r } else { slotMenuReplace = nil }
        selectedIndex = 0
        refocus()
    }

    /// The "create project" pill of an unresolved `#name`: the token leaves the text and a
    /// destination that will be created on submit takes its place.
    func commitUnresolved() {
        guard let u = resolved.unresolvedDestination else { return }
        cut(u.range)
        pills = EntryDraft.setting(.destination(EntryDestination(kind: .project, name: u.name, isNew: true)), in: pills)
        refocus()
    }

    /// After an add. Without `keepingPills` the field is empty; with it the pills stay (batch
    /// entry into the same project) and only the text goes.
    func clear(keepingPills: Bool) {
        let kept = keepingPills ? EntryDraft.pillsToKeep(after: resolved) : []
        slotMenu = nil
        slotMenuReplace = nil
        dismissedKey = nil
        setText("", caret: 0)
        // The text view recorded the typing and this clearing as its own undo steps; left there,
        // the first Cmd-Z after an add would retype the entry instead of undoing the add.
        textView?.undoManager?.removeAllActions()
        pills = kept
    }

    // MARK: Text edits

    private func cut(_ range: Range<Int>) {
        let (new, caret) = EntryEdit.removing(range, from: text)
        setText(new, caret: caret)
    }

    /// Replaces the whole text. Through the text view when there is one, so the edit is a normal
    /// undoable edit and the binding sees it exactly like typing; plain assignment otherwise
    /// (snapshots, tests).
    func setText(_ new: String, caret: Int) {
        if let tv = textView, tv.window != nil {
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            if tv.shouldChangeText(in: full, replacementString: new) {
                tv.replaceCharacters(in: full, with: new)
                tv.didChangeText()
            }
            tv.setSelectedRange(NSRange(location: min(caret, (new as NSString).length), length: 0))
        }
        text = new
        setCaret(caret, hasSelection: false)
    }

    /// Selects the whole text, so typing replaces a starting title the field was given.
    func selectAllText() {
        guard let tv = textView, tv.window != nil else { return }
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        setCaret((tv.string as NSString).length, hasSelection: !text.isEmpty)
    }

    private func refocus() {
        guard let tv = textView, let window = tv.window, window.firstResponder !== tv else { return }
        window.makeFirstResponder(tv)
    }
}
