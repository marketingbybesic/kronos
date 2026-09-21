// Kronos/MenuBar/MenuBarBlockBanner.swift
// BLOCK — the calendar time-block suggestion in the popover: the coach's own sentence
// ("<project> block until <time>") plus Switch / Stay, and — for a block the coach could not
// match — a "This block is for…" project picker that teaches the link
// (`model.coach.link(eventTitle:to:)`). A calm "Allow access" row replaces all of this when
// Calendar access is missing, per ui-common's rule: never crash, never nag, missing access
// always degrades to one quiet row with a button that opens the right System Settings pane.
// This file takes plain values (never reads `model.coach` itself) so the same view renders
// live state and a snapshot fixture alike — `model.coach.refreshBlocks()` talks to the real
// EventKit calendar and must never run inside the snapshot harness: no consent prompt with
// nobody present to answer it.
//
// Every string below is a REAL catalog key whose meaning matches the control it labels: a
// borrowed key that says the wrong thing is worse than a missing one.
// coach.block.switch/stay/starting/inside/linkto/today/link all landed on main.
import SwiftUI
import AppKit
import KronosCore

struct MenuBarBlockBanner: View {
    let suggestion: BlockSuggestion?
    /// Present only when the suggestion could not be matched to a project — offers the
    /// teaching picker. nil when there is nothing unmatched to ask about.
    let unmatchedEventTitle: String?
    let projects: [KProject]
    let onSwitch: () -> Void
    let onStay: () -> Void
    let onLink: (KProject) -> Void

    var body: some View {
        if let suggestion {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text(sentence(for: suggestion))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.x4) {
                    Button(String(localized: "coach.block.switch"), action: onSwitch)
                        .buttonStyle(.plain)
                        .font(Typo.metaStrong)
                        .foregroundStyle(Tok.textPrimary)
                        .fixedSize()
                    Button(String(localized: "coach.block.stay"), action: onStay)
                        .buttonStyle(.plain)
                        .font(Typo.metaStrong)
                        .foregroundStyle(Tok.textSecondary)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
            }
            .padding(Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tok.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        } else if let unmatchedEventTitle {
            linkPicker(for: unmatchedEventTitle)
        }
    }

    /// The coach speaking the fact plainly — coach principle 4/6: no question mark, no
    /// pressure, says WHY (which block, until when). `.starting` vs `.insideBlock` only
    /// changes the preposition (the app woke up already inside the block).
    private func sentence(for s: BlockSuggestion) -> String {
        let time = Self.timeFormatter.string(from: s.endsAt)
        switch s.kind {
        case .starting:
            return String(format: String(localized: "coach.block.starting"), s.projectName, time)
        case .insideBlock:
            return String(format: String(localized: "coach.block.inside"), s.projectName, time)
        }
    }

    private func linkPicker(for eventTitle: String) -> some View {
        KMenuButton(text: String(localized: "coach.block.linkto")) {
            ForEach(projects) { project in
                Button(project.name) { onLink(project) }
            }
        } leading: {
            Icon("calendar", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
        }
    }

    /// Short, locale-aware time-of-day (12h with AM/PM or 24h, matching the system
    /// preference) — never a hardcoded "HH:mm", which would ignore that preference.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

/// A calm, non-nagging stand-in for the whole block section when Calendar access has not
/// been granted — nobody is present to answer the macOS consent dialog, so this is the only
/// thing shown instead.
struct MenuBarCalendarAccessRow: View {
    var body: some View {
        HStack(spacing: Space.x2) {
            Icon("calendar", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
            Text(String(localized: "empty.calendar.access"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(2)
            Spacer(minLength: Space.x2)
            Button(String(localized: "empty.calendar.action"), action: openCalendarSettings)
                .buttonStyle(.plain)
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
                .fixedSize()
        }
        .padding(Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func openCalendarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// TODAY'S BLOCKS strip (feature K): every timed event today, collapsed to the next 3 —
/// a matched one shows its project glyph + name; an unmatched one shows a quiet
/// `coach.block.link` action that opens the SAME teaching picker the main banner uses
/// (`onLink`), for the given event.
struct MenuBarTodaysBlocksStrip: View {
    let blocks: [(event: KCalendarEvent, projectID: UUID?)]
    let projectName: (UUID) -> String?
    let onLinkEvent: (KCalendarEvent) -> Void

    private var collapsed: [(event: KCalendarEvent, projectID: UUID?)] { Array(blocks.prefix(3)) }

    var body: some View {
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(String(localized: "coach.block.today"))
                    .font(Typo.caption)
                    .tracking(Tracking.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.x2) {
                        ForEach(collapsed, id: \.event.id) { block in
                            chip(block)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ block: (event: KCalendarEvent, projectID: UUID?)) -> some View {
        if let id = block.projectID, let name = projectName(id) {
            KChip(name) {
                Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            }
        } else {
            KChip(String(localized: "coach.block.link"), onTap: { onLinkEvent(block.event) }) {
                Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            }
        }
    }
}
