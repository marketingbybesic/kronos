// Deadline attribute control: a button showing KDeadlineLabel, opening a popover with
// quick picks + a graphical date picker. Stores dueDay via store.setDue.
import SwiftUI
import KronosCore

struct InspectorDeadlineControl: View {
    let model: AppModel
    let task: KTask
    @State private var isPresented = false

    var body: some View {
        // No leading calendar icon here: the column's own "Deadline" caption above
        // already says what this control is (matching effort/priority, which lead with
        // their glyph instead since they have no room for both a glyph and a caption-
        // duplicating icon). Freed the width "Sep 15" + the "4d" carry pill needs — the
        // icon + KDeadlineLabel combination truncated to "Sep…" in the 3-column layout
        // (caught on the 360pt screenshot read).
        // Root cause of "must click 2-3 times" (team-lead, live UI test): `.buttonStyle(.plain)`
        // only makes the label's OPAQUE pixels pressable — `.contentShape` chained AFTER
        // `.buttonStyle(.plain)` is a dead wrapper outside the actual button. Moved inside
        // the label closure.
        Button { isPresented = true } label: {
            HStack(spacing: Space.x1) {
                KDeadlineLabel(text: deadlineText, carryDays: task.carryDays(today: Day.today()), isDone: task.status == .done)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            InspectorDeadlinePopover(model: model, task: task)
        }
    }

    /// Short label so the deadline control fits its column next to effort and priority —
    /// a full relative phrase ("9 days ago") wrapped the carry pill onto two lines
    /// (caught on the first screenshot read). Today/Tomorrow use the deadline.quick.*
    /// keys (already short); anything else follows the APP language, not a bare numeric
    /// date ("15/09" reads ambiguously as day/month vs month/day and doesn't move with
    /// KronosLocale) — "d MMM" gives "15 Sep" in English and "15. ruj" in Croatian.
    private var deadlineText: String {
        guard let day = task.dueDay else { return String(localized: "deadline.quick.none") }
        let today = Day.today()
        if day == today { return String(localized: "deadline.quick.today") }
        if day == today + 1 { return String(localized: "deadline.quick.tomorrow") }
        return Self.dayFormatter.string(from: Day.date(day))
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
}

struct InspectorDeadlinePopover: View {
    let model: AppModel
    let task: KTask
    @State private var pickedDate: Date

    init(model: AppModel, task: KTask) {
        self.model = model
        self.task = task
        _pickedDate = State(initialValue: task.dueDay.map { Day.date($0) } ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            InspectorSectionCaption(String(localized: "deadline.pick"))

            VStack(alignment: .leading, spacing: Space.x1) {
                quickPick(String(localized: "deadline.quick.today")) { set(Day.today()) }
                quickPick(String(localized: "deadline.quick.tomorrow")) { set(Day.today() + 1) }
                quickPick(String(localized: "deadline.quick.nextweek")) { set(Day.today() + 7) }
                quickPick(String(localized: "deadline.quick.none")) { set(nil) }
            }

            KHairline()

            DatePicker(String(localized: "deadline.pick"), selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .onChange(of: pickedDate) { _, newValue in set(Day.from(newValue)) }
        }
        .padding(Space.x4)
        .frame(width: 260)
        .background(Tok.overlay)
    }

    private func quickPick(_ title: String, _ action: @escaping () -> Void) -> some View {
        // Same dead-wrapper fix as the deadline button above: frame + contentShape belong
        // inside the label, not chained after `.buttonStyle(.plain)`.
        Button(action: action) {
            Text(title)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Metrics.controlCompact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func set(_ day: Int?) {
        model.store.setDue(task.id, day: day)
        model.didMutate()
    }
}
