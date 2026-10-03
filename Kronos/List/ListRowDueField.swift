// Kronos/List/ListRowDueField.swift
// The date field of a row (key D, a click on the date slot) and of the bulk bar's Pick…: a typed
// date ("fri", "pet", "25.10.", "tomorrow") read by the same grammar quick add uses, plus the four
// fixed choices every date menu offers: Today · Tomorrow · Next week · Clear. Return writes the
// typed date; text that is not a date writes nothing and says so; Esc closes.
import SwiftUI
import KronosCore

/// Resolves typed date text to a day number, through quick add's own parser (no second grammar).
enum ListTypedDate {
    static func day(from text: String, today: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return QuickAddParser().parse(trimmed, projects: [], today: today, calendar: KronosLocale.calendar).dueDay
    }
}

struct ListDueField: View {
    /// The task's current deadline, for the check mark on a matching choice and for Clear.
    let current: Int?
    /// Writes the chosen day (nil clears) and closes.
    let onPick: (Int?) -> Void
    @State private var text = ""
    @State private var unreadable = false

    var body: some View {
        let today = Day.today()
        VStack(alignment: .leading, spacing: Space.x2) {
            KTextField(String(localized: "list.due.field.placeholder"), text: $text, leading: "calendar", autofocus: true)
                .frame(width: 220)
                .onSubmit { submit(today: today) }
                .onChange(of: text) { _, _ in unreadable = false }
                .uiTestAnchor("list.due.field")
            if unreadable {
                Text(String(localized: "list.due.field.unreadable"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            choice(String(localized: "deadline.quick.today"), today, today: today)
            choice(String(localized: "deadline.quick.tomorrow"), today + 1, today: today)
            choice(String(localized: "deadline.quick.nextweek"), today + 7, today: today)
            if current != nil {
                Button(String(localized: "ctx.field.clear")) { onPick(nil) }
                    .buttonStyle(.plain)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .frame(minHeight: Metrics.minHit)
                    .contentShape(Rectangle())
            }
        }
        .fixedSize(horizontal: true, vertical: false)   // as wide as the field, not the window
        .padding(Space.x3)
        .background(Tok.overlay)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "hotkey.list.due"))
    }

    private func choice(_ title: String, _ day: Int, today: Int) -> some View {
        Button {
            onPick(day)
        } label: {
            HStack(spacing: Space.x2) {
                Text(title)
                Spacer(minLength: Space.x4)
                if current == day { Icon("check", size: Metrics.iconXS).accessibilityHidden(true) }
            }
            .frame(minHeight: Metrics.minHit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(Typo.row)
        .foregroundStyle(Tok.textPrimary)
    }

    private func submit(today: Int) {
        guard let day = ListTypedDate.day(from: text, today: today) else {
            unreadable = !text.trimmingCharacters(in: .whitespaces).isEmpty
            return
        }
        onPick(day)
    }
}
