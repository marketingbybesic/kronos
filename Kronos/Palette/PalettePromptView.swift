// Kronos/Palette/PalettePromptView.swift
// The palette's second step for the three commands that need one more answer: "Move to…",
// "Pick…" (a date) and "Rename…". Same card, same keys (↑ ↓ ⏎, esc goes back to the commands);
// the field now holds the answer. Rows come from PalettePromptLogic, so what is offered for a
// typed phrase is table-tested apart from this view.
import SwiftUI
import KronosCore

enum PalettePrompt: Equatable {
    case moveTo(UUID)
    case pickDate(UUID)
    case rename(UUID)

    var taskID: UUID {
        switch self {
        case .moveTo(let id), .pickDate(let id), .rename(let id): return id
        }
    }
}

/// A command's run closure cannot reach the palette view, so it leaves its request here and the
/// view picks it up right after the command ran.
@MainActor
final class PalettePromptCenter {
    static let shared = PalettePromptCenter()
    private(set) var pending: PalettePrompt?
    private init() {}

    func request(_ prompt: PalettePrompt) { pending = prompt }

    @discardableResult
    func take() -> PalettePrompt? {
        defer { pending = nil }
        return pending
    }
}

struct PalettePromptView: View {
    let model: AppModel
    let prompt: PalettePrompt
    let onBack: () -> Void
    /// Snapshot-only seeding: text already typed in the field. Empty in the app.
    var initialQuery: String = ""

    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var isFieldFocused: Bool

    /// One selectable answer.
    private struct Option: Identifiable {
        let id: String
        let title: String
        let glyph: String
        var projectIcon: String? = nil
        var projectColorHex: String? = nil
        let apply: @MainActor () -> Void
    }

    private var task: KTask? { model.store.task(prompt.taskID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            KHairline()
            field
            KHairline()
            if options.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.x1) {
                        ForEach(options) { option in row(option) }
                    }
                    .padding(.horizontal, Space.x2)
                    .padding(.vertical, Space.x2)
                }
                .frame(height: listHeight)
            }
            KHairline()
            footer
        }
        .frame(maxWidth: 560)
        .uiTestAnchor("palette.prompt")
        .onAppear {
            if !initialQuery.isEmpty { query = initialQuery } else if case .rename = prompt { query = task?.title ?? "" }
            selectedID = options.first?.id
            DispatchQueue.main.async { isFieldFocused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isFieldFocused = true }
        }
        .onChange(of: query) { _, _ in selectedID = options.first?.id }
    }

    /// The list is as tall as its rows, up to 420 pt; a lone row does not sit in a tall empty box.
    private var listHeight: CGFloat {
        let n = CGFloat(options.count)
        return min(n * Metrics.rowHeight + max(n - 1, 0) * Space.x1 + Space.x2 * 2, 420)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: Space.x2) {
            Text(commandTitle).font(Typo.rowStrong).foregroundStyle(Tok.textPrimary)
            Text(task?.title ?? "")
                .font(Typo.row).foregroundStyle(Tok.textTertiary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.controlCompact)
        .accessibilityElement(children: .combine)
    }

    private var field: some View {
        HStack(spacing: Space.x2) {
            Icon(fieldGlyph, size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Tok.textPrimary)
                .focused($isFieldFocused)
                .accessibilityLabel(commandTitle)
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.toolbarHeight)
        .background(PaletteKeyCatcher(onKey: handle))
    }

    private var emptyState: some View {
        Text("palette.empty").font(Typo.row).foregroundStyle(Tok.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.x6)
    }

    private var footer: some View {
        HStack(spacing: Space.x4) {
            KKeyHintItem(["↑", "↓"], label: String(localized: "palette.hint.navigate"))
            KKeyHintItem(["⏎"], label: String(localized: "palette.hint.apply"))
            KKeyHintItem(["esc"], label: String(localized: "palette.hint.back"))
            Spacer()
        }
        .padding(.horizontal, Space.x4)
        .frame(height: Metrics.controlCompact)
        .accessibilityHidden(true)
    }

    private func row(_ option: Option) -> some View {
        PaletteRow(isSelected: option.id == selectedID, title: option.title, accessibilityLabel: option.title,
                   onSelect: { selectedID = option.id; apply(option) },
                   leading: {
                       if option.projectIcon != nil || option.projectColorHex != nil {
                           KProjectGlyph(icon: option.projectIcon, colorHex: option.projectColorHex, size: Metrics.iconM)
                       } else {
                           Icon(option.glyph, size: Metrics.iconM).foregroundStyle(Tok.textSecondary)
                       }
                   },
                   trailing: { EmptyView() })
    }

    // MARK: Per-prompt text

    private var commandTitle: String {
        switch prompt {
        case .moveTo: return String(localized: "palette.task.moveto")
        case .pickDate: return String(localized: "ctx.task.due")
        case .rename: return String(localized: "palette.task.rename")
        }
    }

    private var placeholder: String {
        switch prompt {
        case .moveTo: return String(localized: "palette.prompt.move.placeholder")
        case .pickDate: return String(localized: "palette.prompt.date.placeholder")
        case .rename: return String(localized: "palette.prompt.rename.placeholder")
        }
    }

    private var fieldGlyph: String {
        switch prompt {
        case .moveTo: return "folder"
        case .pickDate: return "calendar"
        case .rename: return "pencil"
        }
    }

    // MARK: Options

    private var options: [Option] {
        guard let task else { return [] }
        switch prompt {
        case .moveTo: return moveOptions(task)
        case .pickDate: return dateOptions(task)
        case .rename: return renameOptions(task)
        }
    }

    private func moveOptions(_ task: KTask) -> [Option] {
        let projects = model.store.allProjects()
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let offered = PalettePromptLogic.projectRows(
            query: query, projects: projects.map { PaletteProjectOption(id: $0.id, name: $0.name) },
            noneName: String(localized: "detail.noproject"), currentID: task.projectID,
            recents: recents(of: projects))
        let id = task.id
        return offered.map { option in
            let project = option.id.flatMap { byID[$0] }
            return Option(id: option.id?.uuidString ?? "none", title: option.name,
                          glyph: project == nil ? "inbox" : "folder",
                          projectIcon: project?.icon, projectColorHex: project?.colorHex) {
                guard model.store.task(id)?.projectID != project?.id else { return }
                PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "undo.moved.name"), option.name)) {
                    model.store.move(id, toProject: project)
                }
            }
        }
    }

    /// When each project last received a task through an entry field, for the empty-query order.
    private func recents(of projects: [KProject]) -> [UUID: Date] {
        let table = EntryRecents()
        return Dictionary(uniqueKeysWithValues: projects.compactMap { p in table.lastUsed(.project(p.id)).map { (p.id, $0) } })
    }

    private func dateOptions(_ task: KTask) -> [Option] {
        let today = Day.today(calendar: KronosLocale.calendar)
        let names: [PaletteDateRow.Kind: String] = [
            .today: String(localized: "deadline.quick.today"),
            .tomorrow: String(localized: "deadline.quick.tomorrow"),
            .nextWeek: String(localized: "deadline.quick.nextweek"),
            .clear: String(localized: "ctx.field.clear"),
        ]
        let rows = PalettePromptLogic.dateRows(query: query, today: today, hasDue: task.dueDay != nil,
                                               names: names, calendar: KronosLocale.calendar)
        let id = task.id
        return rows.map { row in
            let title = row.kind == .parsed ? (row.day.map(DeadlineFormatter.withWeekday(day:)) ?? "") : (names[row.kind] ?? "")
            return Option(id: row.kind.rawValue, title: title, glyph: "calendar") {
                guard let current = model.store.task(id), current.dueDay != row.day else { return }
                let message = row.day == nil
                    ? PaletteCommit.text(String(localized: "palette.undo.duecleared"), current.title)
                    : PaletteCommit.text(String(localized: "palette.undo.due"), current.title, title)
                PaletteCommit.run(model, message: message) { model.store.setDue(id, day: row.day) }
            }
        }
    }

    private func renameOptions(_ task: KTask) -> [Option] {
        guard let new = PalettePromptLogic.renamedTitle(current: task.title, typed: query) else { return [] }
        let id = task.id
        return [Option(id: "rename", title: PaletteCommit.text(String(localized: "palette.prompt.rename.row"), new),
                       glyph: "pencil") {
            PaletteCommit.run(model, message: PaletteCommit.text(String(localized: "palette.undo.renamed"), new)) {
                model.store.update(id) { $0.title = new }
            }
        }]
    }

    // MARK: Keys

    private func handle(_ event: NSEvent) -> Bool {
        switch event.specialKey {
        case .some(.upArrow): move(-1); return true
        case .some(.downArrow): move(1); return true
        default: break
        }
        if event.keyCode == 53 { onBack(); return true }                       // Esc
        if event.keyCode == 36 || event.keyCode == 76 {                         // Return / keypad Return
            if let option = options.first(where: { $0.id == selectedID }) { apply(option) }
            return true
        }
        return false
    }

    private func move(_ delta: Int) {
        let items = options
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        selectedID = items[((current + delta) % items.count + items.count) % items.count].id
    }

    private func apply(_ option: Option) {
        option.apply()
        model.isPaletteOpen = false
    }
}
