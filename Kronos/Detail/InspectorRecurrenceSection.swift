// REPEAT — recurrence rule picker. None / Daily / Weekly (weekday toggles) / Monthly
// (day 1...31) / Every N days, plus the anchor choice, using RecurrenceRule's own
// wireFormat/parse and description(locale:) for the summary line.
import SwiftUI
import KronosCore

private enum RecurrenceKind: Int, CaseIterable, Identifiable {
    case none, daily, weekly, monthly, everyNDays
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "detail.recurrence.none")
        case .daily: String(localized: "detail.recurrence.daily")
        case .weekly: String(localized: "detail.recurrence.weekly")
        case .monthly: String(localized: "detail.recurrence.monthly")
        case .everyNDays: String(localized: "detail.recurrence.everyndays.menu")
        }
    }
}

struct InspectorRecurrenceSection: View {
    let model: AppModel
    let task: KTask
    @State private var isPresented = false

    var body: some View {
        // Borderless property list row (style G): the summary line IS the value —
        // no boxed control, no leading icon (the label column already says "Repeat").
        // The full kind/weekday/anchor picker opens from it in a popover.
        KPropertyRow(String(localized: "detail.recurrence"), value: summary, isPlaceholder: rule == nil)
            .contentShape(Rectangle())
            .onTapGesture { isPresented = true }
            .popover(isPresented: $isPresented) {
                InspectorRecurrenceEditor(rule: rule, locale: KronosLocale.languageCode) { newRule in
                    model.store.setRecurrence(task.id, newRule?.wireFormat)
                    model.didMutate()
                }
                .padding(Space.x4)
                .frame(width: 280)
                .background(Tok.overlay)
            }
    }

    private var rule: RecurrenceRule? {
        task.recurrenceRule.flatMap(RecurrenceRule.parse)
    }

    private var summary: String {
        rule.map { $0.description(locale: KronosLocale.languageCode) } ?? String(localized: "detail.recurrence.none")
    }
}

/// The picker's own state machine, isolated from the store so it can be snapshotted with
/// a fixed sample rule (DetailSnapshots' `inspector.recurrence`).
struct InspectorRecurrenceEditor: View {
    let locale: String
    let onChange: (RecurrenceRule?) -> Void
    @State private var kind: RecurrenceKind
    @State private var every: Int
    @State private var weekdays: Set<Int>
    @State private var monthDay: Int
    @State private var everyNDays: Int
    @State private var anchor: RecurrenceAnchor

    init(rule: RecurrenceRule?, locale: String, onChange: @escaping (RecurrenceRule?) -> Void) {
        self.locale = locale
        self.onChange = onChange
        switch rule {
        case .none:
            _kind = State(initialValue: .none); _every = State(initialValue: 1)
            _weekdays = State(initialValue: [1]); _monthDay = State(initialValue: 1)
            _everyNDays = State(initialValue: 1); _anchor = State(initialValue: .fromDueDay)
        case .daily(let e, let a):
            _kind = State(initialValue: .daily); _every = State(initialValue: e)
            _weekdays = State(initialValue: [1]); _monthDay = State(initialValue: 1)
            _everyNDays = State(initialValue: 1); _anchor = State(initialValue: a)
        case .weekly(let e, let d, let a):
            _kind = State(initialValue: .weekly); _every = State(initialValue: e)
            _weekdays = State(initialValue: d); _monthDay = State(initialValue: 1)
            _everyNDays = State(initialValue: 1); _anchor = State(initialValue: a)
        case .monthly(let e, let d, let a):
            _kind = State(initialValue: .monthly); _every = State(initialValue: e)
            _weekdays = State(initialValue: [1]); _monthDay = State(initialValue: d)
            _everyNDays = State(initialValue: 1); _anchor = State(initialValue: a)
        case .yearly:
            // yearly has no picker row in this leaf's scope (not named in the ledger); it
            // still round-trips read-only via the summary line below.
            _kind = State(initialValue: .none); _every = State(initialValue: 1)
            _weekdays = State(initialValue: [1]); _monthDay = State(initialValue: 1)
            _everyNDays = State(initialValue: 1); _anchor = State(initialValue: .fromDueDay)
        case .everyNDays(let n):
            _kind = State(initialValue: .everyNDays); _every = State(initialValue: 1)
            _weekdays = State(initialValue: [1]); _monthDay = State(initialValue: 1)
            _everyNDays = State(initialValue: n); _anchor = State(initialValue: .fromCompletionDay)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            KMenuButton(text: kind.title) {
                ForEach(RecurrenceKind.allCases) { k in
                    Button {
                        kind = k
                        push()
                    } label: {
                        if k == kind { Label(k.title, systemImage: "checkmark") } else { Text(k.title) }
                    }
                }
            } leading: {
                Icon("repeat", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            }

            switch kind {
            case .none: EmptyView()
            case .daily: EmptyView()
            case .weekly: weekdayToggles
            case .monthly: monthDayStepper
            case .everyNDays: everyNDaysStepper
            }

            if kind != .none && kind != .everyNDays {
                anchorPicker
            }

            if let currentRule {
                Text(currentRule.description(locale: locale))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
            }
        }
    }

    private var weekdayToggles: some View {
        // Two letters, not one: in Croatian one letter gives "p u s č p s n" (two p, two s).
        let symbols = KronosLocale.calendar.shortStandaloneWeekdaySymbols.map { String($0.prefix(2)).lowercased() }   // Mon-first order handled by index math below
        return HStack(spacing: Space.x1) {
            ForEach(1...7, id: \.self) { iso in
                let label = symbols[(iso % 7)]
                let isOn = weekdays.contains(iso)
                Button {
                    if isOn { weekdays.remove(iso) } else { weekdays.insert(iso) }
                    if !weekdays.isEmpty { push() }
                } label: {
                    Text(label)
                        .font(Typo.metaStrong)
                        .foregroundStyle(isOn ? Tok.textOnAccent : Tok.textSecondary)
                        .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
                        .background(Circle().fill(isOn ? Tok.textPrimary : Tok.hoverFill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private var monthDayStepper: some View {
        Stepper(value: $monthDay, in: 1...31) {
            Text("\(monthDay)").font(Typo.row).foregroundStyle(Tok.textPrimary)
        }
        .onChange(of: monthDay) { _, _ in push() }
    }

    private var everyNDaysStepper: some View {
        Stepper(value: $everyNDays, in: 1...365) {
            // Croatian needs one/few/many ("1 dan" / "2 dana" / "5 dana"); a single %lld
            // pattern used for every count is wrong at exactly this stepper's default (n=1).
            Text(KPlural.hr(everyNDays,
                            one: String(localized: "detail.recurrence.after.one"),
                            few: String(localized: "detail.recurrence.after.few"),
                            many: String(localized: "detail.recurrence.after.many")))
                .font(Typo.row).foregroundStyle(Tok.textPrimary)
        }
        .onChange(of: everyNDays) { _, _ in push() }
    }

    private var anchorPicker: some View {
        Picker(String(localized: "detail.recurrence"), selection: $anchor) {
            Text(String(localized: "detail.recurrence.anchor.due")).tag(RecurrenceAnchor.fromDueDay)
            Text(String(localized: "detail.recurrence.anchor.completion")).tag(RecurrenceAnchor.fromCompletionDay)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: anchor) { _, _ in push() }
    }

    private var currentRule: RecurrenceRule? {
        switch kind {
        case .none: nil
        case .daily: .daily(every: max(1, every), anchor: anchor)
        case .weekly: weekdays.isEmpty ? nil : .weekly(every: max(1, every), weekdays: weekdays, anchor: anchor)
        case .monthly: .monthly(every: max(1, every), day: monthDay, anchor: anchor)
        case .everyNDays: .everyNDays(max(1, everyNDays))
        }
    }

    private func push() { onChange(currentRule) }
}
