// The Deadline popover exactly as it ships. InspectorDeadlineControl presents it and the snapshot
// harness renders this same view (InspectorSnapshots "inspector.deadline").
//
// Layout: a padded header (caption + four quick picks), a hairline, then a month calendar that
// runs the popover's full width. The system graphical DatePicker cannot do that on macOS (it
// keeps a fixed ~136 pt size and, as first responder, draws an accent-coloured focus ring around
// itself), so the month is drawn here from plain buttons: seven equal columns across the whole
// width, native-sized controls, no ring.
import SwiftUI
import KronosCore

/// Pure month arithmetic for the calendar, separated from the view so a live step can check it
/// against a hand-written table.
enum DeadlineMonth {
    /// Every day shown for the month containing `month`: whole weeks, starting on the calendar's
    /// first weekday, including the neighbouring months' days that complete the first and last week.
    static func days(of month: Date, calendar: Calendar) -> [Date] {
        guard let first = calendar.dateInterval(of: .month, for: month)?.start,
              let count = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let total = (leading + count + 6) / 7 * 7
        return (0..<total).compactMap { calendar.date(byAdding: .day, value: $0 - leading, to: first) }
    }

    /// Two-letter weekday headers in the calendar's own order ("Mo Tu ...", "po ut ...").
    static func weekdayHeaders(calendar: Calendar) -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return [] }
        return (0..<7).map { String(symbols[(calendar.firstWeekday - 1 + $0) % 7].prefix(2)).capitalized }
    }
}

struct InspectorDeadlinePopover: View {
    /// Space between the popover edge and the caption / quick picks / calendar cells.
    static let inset = Space.x4
    static let calendarInset = Space.x3
    static let width: CGFloat = 300

    let model: AppModel
    let task: KTask
    @State private var selected: Int?
    @State private var shownMonth: Date
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, task: KTask) {
        self.model = model
        self.task = task
        _selected = State(initialValue: task.dueDay)
        _shownMonth = State(initialValue: task.dueDay.map { Day.date($0) } ?? Date())
    }

    private var calendar: Calendar { KronosLocale.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.x3) {
                InspectorSectionCaption(String(localized: "deadline.pick"))
                Grid(horizontalSpacing: Space.x2, verticalSpacing: Space.x2) {
                    GridRow {
                        quickPick(String(localized: "deadline.quick.today")) { set(Day.today()) }
                        quickPick(String(localized: "deadline.quick.tomorrow")) { set(Day.today() + 1) }
                    }
                    GridRow {
                        quickPick(String(localized: "deadline.quick.nextweek")) { set(Day.today() + 7) }
                        quickPick(String(localized: "deadline.quick.none")) { set(nil) }
                    }
                }
            }
            .padding(Self.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .uiTestAnchor("deadline.popover.header")

            KHairline()

            monthCalendar
                .padding(.horizontal, Self.calendarInset)
                .padding(.top, Space.x2)
                .padding(.bottom, Space.x3)
                .frame(maxWidth: .infinity)
                .uiTestAnchor("deadline.popover.calendar")
        }
        .frame(width: Self.width)
        .background(Tok.overlay, ignoresSafeAreaEdges: .all)
        .uiTestAnchor("deadline.popover.root")
    }

    // MARK: Month calendar

    private var monthCalendar: some View {
        let days = DeadlineMonth.days(of: shownMonth, calendar: calendar)
        let today = Day.today()
        return VStack(spacing: Space.x1) {
            HStack(spacing: Space.x1) {
                Text(Self.monthTitle(shownMonth))
                    .font(Typo.rowStrong)
                    .foregroundStyle(Tok.textPrimary)
                    .padding(.leading, Space.x1)
                Spacer(minLength: 0)
                navButton("chevron.left", label: String(localized: "deadline.month.previous")) { moveMonth(-1) }
                navButton("circle.fill", label: String(localized: "deadline.quick.today"), small: true) { shownMonth = Date() }
                navButton("chevron.right", label: String(localized: "deadline.month.next")) { moveMonth(1) }
            }
            .frame(height: Metrics.controlCompact)

            HStack(spacing: 0) {
                ForEach(Array(DeadlineMonth.weekdayHeaders(calendar: calendar).enumerated()), id: \.offset) { _, h in
                    Text(h)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(0..<(days.count / 7), id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(days[week * 7 + col], today: today)
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date, today: Int) -> some View {
        let day = Day.from(date)
        let inMonth = calendar.isDate(date, equalTo: shownMonth, toGranularity: .month)
        let isSelected = day == selected
        let isToday = day == today
        return Button { set(day); dismiss() } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(isToday ? Typo.rowStrong : Typo.row)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Tok.textOnAccent : (inMonth ? Tok.textPrimary : Tok.textTertiary))
                .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
                .background(Circle().fill(isSelected ? Tok.textPrimary : Color.clear))
                .overlay(Circle().strokeBorder(isToday && !isSelected ? Tok.textSecondary : Color.clear, lineWidth: 1))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.fullDate(date))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .uiTestAnchor(inMonth ? "deadline.popover.day.\(day)" : "deadline.popover.outside.\(day)")
    }

    private func navButton(_ symbol: String, label: String, small: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: small ? 6 : 11, weight: .semibold))
                .foregroundStyle(Tok.textSecondary)
                .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func moveMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: shownMonth) { shownMonth = next }
    }

    // MARK: Pieces

    private func quickPick(_ title: String, _ action: @escaping () -> Void) -> some View {
        // Same dead-wrapper fix as the deadline button: frame + contentShape belong inside the
        // label, not chained after `.buttonStyle(.plain)`.
        Button { action(); dismiss() } label: {
            Text(title)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.controlCompact)
                .background(RoundedRectangle(cornerRadius: Radius.row).fill(Tok.hoverFill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func set(_ day: Int?) {
        selected = day
        model.store.setDue(task.id, day: day)
        model.didMutate()
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("LLLL y")
        return f
    }()

    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.dateStyle = .full
        return f
    }()

    private static func monthTitle(_ date: Date) -> String { monthFormatter.string(from: date).capitalized }
    private static func fullDate(_ date: Date) -> String { fullFormatter.string(from: date) }
}
