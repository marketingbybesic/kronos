// Kronos/Detail/InspectorCalendarSection.swift — the task's calendar-block link.
// Split out of InspectorCoachSection.swift purely to stay under the 500-line file cap; same
// feature family (task <-> Apple Notes / context link / calendar link rows).
import SwiftUI
import AppKit
import KronosCore

// MARK: - Calendar block link

/// Shows the task's linked calendar block (`TaskCalendarLink`, its own `cal://` line —
/// KronosCore/Coach/ContextLinkCalendar.swift), or today's blocks to link with one click when
/// none is linked yet, with recurring blocks or repeated names auto-linking on match. Reads
/// `model.coach.todaysBlocks` (CoachModel, a frozen contract type, read-only here) rather than
/// talking to EventKit directly — the same allow-row CoachModel already exposes for missing
/// access.
struct InspectorCalendarBlockRow: View {
    let model: AppModel
    let task: KTask
    /// Snapshot-only: forces the disclosure open on appear (`inspector.block.open`) — the
    /// real screen never sets this. `model.coach.todaysBlocks` always wraps the real
    /// EventKitCalendar (UIContract.swift, a frozen contract file with no fixture-injection
    /// seam reachable here — BlockSnapshotHost's own doc comment), so a harness process
    /// cannot seed fake unlinked blocks to expand into; this still proves the disclosure
    /// chrome itself (header row, chevron rotation) on whatever real blocks (if any) the
    /// render machine has.
    var forceExpandedOnAppear: Bool = false
    /// Collapsed by default to ONE line; the disclosure opens the list, state remembered per
    /// session — plain `@State`, same per-session-only scope as the list's own
    /// `TaskListScreen.isNowCardCollapsed`, not a persisted pref.
    @State private var isExpanded = false

    private var link: TaskCalendarLink? { TaskCalendarLink.find(in: task.notes) }

    /// `KAllowAccessRow` (Settings' own full-window-width component — off-limits to edit,
    /// ui-common.md) squeezed into `KPropertyRow`'s ~280pt value column at the inspector's
    /// narrow width overlapped its own text and button (caught on the 420pt HR screenshot
    /// read: "Kronos nema pristup kalendaru" wrapped under a floating "Dopusti pristup
    /// kalendaru" pill, on top of the row below it). Fixed by giving the not-granted state
    /// the section's FULL width — its own caption + full-bleed row, like First move/Steps —
    /// instead of forcing it through the label+value split that only the compact one-line
    /// "granted" states actually fit.
    var body: some View {
        // Root cause of a prior "Unlink does nothing" bug: `task` is re-fetched fresh from
        // `model.store` by the PARENT (InspectorScreen) on every `body` call, but nothing in
        // this file read `model.version`, so `@Observable` had no reason to re-run `body`
        // right after `unlink()` called `model.didMutate()` — every other screen that
        // re-derives from `model.store` after a mutation reads `model.version` explicitly for
        // exactly this reason (SidebarArchived.swift, SidebarSavedViews.swift,
        // SidebarScreen.swift, MenuBarOrdoController.swift, QuickAddPanelView.swift). The row's
        // own state was correct all along (`unlink()` -> `TaskCalendarLink.removing(from:)` ->
        // `model.didMutate()`); it just never got told to redraw with it.
        let _ = model.version
        VStack(alignment: .leading, spacing: Space.x2) {
            InspectorSectionCaption(String(localized: "detail.calendar.section"))
            switch model.coach.calendarAccess {
            case .notDetermined, .denied:
                KAllowAccessRow(
                    message: String(localized: "empty.calendar.access"),
                    buttonTitle: model.coach.calendarAccess == .denied
                        ? String(localized: "settings.calendars.opensystem")
                        : String(localized: "settings.calendars.grant")
                ) {
                    if model.coach.calendarAccess == .denied {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        Task { await model.coach.requestCalendarAccess() }
                    }
                }
            case .granted:
                grantedContent
            }
        }
        .task(id: task.id) { autoLinkIfMatched() }
        .onAppear { if forceExpandedOnAppear { isExpanded = true } }
    }

    /// One quiet summary line — the linked block, or an "N blocks today" count when nothing
    /// is linked yet — that opens/closes the full list. A linked task always shows its own
    /// summary row (never collapses further: unlinking is a one-click action that must always
    /// be reachable), so the disclosure only ever hides/reveals the unlinked-blocks picker.
    @ViewBuilder
    private var grantedContent: some View {
        if let link {
            HStack(spacing: Space.x2) {
                Icon("clock", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                Text(String(format: String(localized: "detail.calendar.linked"), blockLabel(link)))
                    .font(Typo.row).foregroundStyle(Tok.textPrimary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: Space.x2)
                Button(String(localized: "detail.calendar.unlink"), action: unlink)
                    .buttonStyle(.plain).font(Typo.meta).foregroundStyle(Tok.textTertiary).fixedSize()
            }
            .frame(height: Metrics.controlRegular)
        } else if unlinkedTodaysBlocks.isEmpty {
            Text(String(localized: "empty.calendar.body"))
                .font(Typo.row)
                .foregroundStyle(Tok.textTertiary)
                .frame(height: Metrics.controlRegular, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                disclosureHeader
                if isExpanded {
                    VStack(alignment: .leading, spacing: Space.x1) {
                        ForEach(unlinkedTodaysBlocks, id: \.event.id) { block in
                            HStack(spacing: Space.x2) {
                                Text(blockLabel(block.event))
                                    .font(Typo.row).foregroundStyle(Tok.textSecondary).lineLimit(1)
                                Spacer(minLength: Space.x2)
                                Button(String(localized: "coach.block.link")) { link(block.event) }
                                    .buttonStyle(.plain).font(Typo.meta).foregroundStyle(Tok.textPrimary).fixedSize()
                            }
                            .frame(height: Metrics.controlRegular)
                        }
                    }
                    .padding(.top, Space.x1)
                }
            }
        }
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(Motion.curve(Motion.fast)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Space.x2) {
                Icon("clock", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                Text(String(format: String(localized: "detail.calendar.today_count"), unlinkedTodaysBlocks.count))
                    .font(Typo.row).foregroundStyle(Tok.textSecondary).lineLimit(1)
                Spacer(minLength: Space.x2)
                Icon(isExpanded ? "chevron-down" : "chevron-right", size: Metrics.iconXS)
                    .foregroundStyle(Tok.textTertiary)
            }
            .frame(height: Metrics.controlRegular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var unlinkedTodaysBlocks: [(event: KCalendarEvent, projectID: UUID?)] {
        model.coach.todaysBlocks
    }

    /// Any block whose title exactly folds-matches this task's title, or a recurring series
    /// already linked once before (a title this task has linked to previously), links itself
    /// without asking. A block that does not match anything is left for the manual list
    /// above; this never guesses on a partial/fuzzy title match (a wrong auto-link would be
    /// worse than asking once).
    private func autoLinkIfMatched() {
        guard link == nil, model.coach.calendarAccess == .granted else { return }
        guard let match = unlinkedTodaysBlocks.first(where: {
            TaskCalendarAutoLink.matches(eventTitle: $0.event.title, subjectName: task.title)
        }) else { return }
        link(match.event)
    }

    private func link(_ event: KCalendarEvent) {
        model.store.update(task.id) { t in
            t.notes = TaskCalendarLink(eventID: event.id, title: event.title, start: event.start, end: event.end)
                .appending(to: t.notes)
        }
        model.didMutate()
    }

    private func unlink() {
        model.store.update(task.id) { t in
            t.notes = TaskCalendarLink.removing(from: t.notes)
        }
        model.didMutate()
    }

    private func blockLabel(_ link: TaskCalendarLink) -> String {
        String(format: String(localized: "coach.block.starting"), link.title, Self.timeFormatter.string(from: link.end))
    }
    private func blockLabel(_ event: KCalendarEvent) -> String {
        String(format: String(localized: "coach.block.starting"), event.title, Self.timeFormatter.string(from: event.end))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
