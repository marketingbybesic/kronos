// Coach/BlockCoach.swift — calendar time blocks linked to projects. Pure:
// no I/O, no clock reads, no calendar access — every input is a value the
// caller already fetched (mirrors RankingEngine's contract). A block change
// is a TRANSITION, so this only speaks once per event, never when the user
// is already in the right project, and both answers ("Stay" and "Switch")
// are equally final — neither is logged as a failure.

import Foundation

/// A project the coach can match a calendar event against.
public struct CoachProject: Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// The project's area name, if any — matched as a fallback keyword,
    /// alongside the project's own name, so linking a block to a project
    /// stays low-effort even without configuring explicit keywords.
    /// Defaulted so every existing call site (and every earlier test)
    /// stays source-compatible.
    public let areaName: String?

    public init(id: UUID, name: String, areaName: String? = nil) {
        self.id = id
        self.name = name
        self.areaName = areaName
    }
}

/// One suggestion to switch (or notice you're already in) a calendar block's
/// project. `.starting` means the event just began (within the lead window);
/// `.insideBlock` means the app woke up or launched while already inside it
/// (e.g. after sleep) — both render the same "Switch / Stay" choice, only the
/// copy differs, which is a UI concern.
public struct BlockSuggestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case starting, insideBlock }

    public let eventID: String
    public let projectID: UUID
    public let projectName: String
    public let endsAt: Date
    public let kind: Kind

    public init(eventID: String, projectID: UUID, projectName: String, endsAt: Date, kind: Kind) {
        self.eventID = eventID
        self.projectID = projectID
        self.projectName = projectName
        self.endsAt = endsAt
        self.kind = kind
    }
}

/// Persists which events have already been answered (Switch or Stay — both
/// count) so a block never repeats its suggestion. Resets on day change: a
/// recurring daily meeting gets a fresh chance to suggest tomorrow.
public struct BlockCoachState: Codable, Equatable, Sendable {
    public var day: Int
    public var answeredEventIDs: Set<String>

    public init(day: Int, answeredEventIDs: Set<String> = []) {
        self.day = day
        self.answeredEventIDs = answeredEventIDs
    }

    /// A fresh state for `today`, carrying over `answeredEventIDs` only when
    /// `today` matches the stored day — otherwise today starts with a clean
    /// slate.
    public func rolledOver(to today: Int) -> BlockCoachState {
        day == today ? self : BlockCoachState(day: today)
    }

    /// Records that `eventID` has been answered (Switch or Stay), returning
    /// the updated state. Idempotent.
    public func answering(_ eventID: String) -> BlockCoachState {
        var copy = self
        copy.answeredEventIDs.insert(eventID)
        return copy
    }
}

/// Matches calendar events to projects and decides when to speak up.
public enum BlockCoach {

    /// Never suggest for a block shorter than this — a 5-minute calendar hold
    /// is not a context switch worth interrupting for.
    public static let minimumEventMinutes = 10

    /// - Parameters:
    ///   - now: the current instant.
    ///   - events: today's calendar events (existing `Calendar/` seam).
    ///     All-day events are never matched, regardless of keywords.
    ///   - projects: candidate projects to match against.
    ///   - keywords: project id -> its match keywords (folded, whole-word).
    ///     A project absent from this map, or mapped to an empty array,
    ///     matches on its own name instead (the settings default).
    ///   - leadMinutes: how far before an event's start it may first fire.
    ///   - focusProjectID: the project of the task currently in focus, or nil
    ///     when nothing is focused (inbox/unassigned tasks never trigger a
    ///     suggestion, since there is no "elsewhere" to be relative to).
    ///   - answeredEventIDs: events already answered today — suppressed.
    ///   - learnedEventTitles: folded event title -> project id, learned from
    ///     a previous "Switch" answer or an explicit "this block is for..."
    ///     pick (`CoachSettings.learnedEventTitles`). Checked before keyword
    ///     matching, since an exact learned match is more confident than any
    ///     inferred one.
    /// - Returns: at most one suggestion — the single soonest-relevant match.
    public static func suggest(now: Date,
                                events: [KCalendarEvent],
                                projects: [CoachProject],
                                keywords: [UUID: [String]],
                                leadMinutes: Int,
                                focusProjectID: UUID?,
                                answeredEventIDs: Set<String>,
                                learnedEventTitles: [String: UUID] = [:]) -> BlockSuggestion? {
        let leadSeconds = TimeInterval(max(0, leadMinutes) * 60)
        let candidates = events.compactMap { event -> (KCalendarEvent, CoachProject, BlockSuggestion.Kind)? in
            guard !event.isAllDay, !answeredEventIDs.contains(event.id) else { return nil }
            guard event.end > now else { return nil } // already ended
            let minutes = event.end.timeIntervalSince(event.start) / 60
            guard minutes >= Double(minimumEventMinutes) else { return nil }

            let startsWithinLead = event.start <= now.addingTimeInterval(leadSeconds)
            let alreadyInside = event.start <= now && event.end > now
            guard startsWithinLead || alreadyInside else { return nil }

            guard let project = matchProject(for: event, projects: projects, keywords: keywords,
                                             learnedEventTitles: learnedEventTitles) else { return nil }
            guard project.id != focusProjectID else { return nil } // silent: focus already matches

            let kind: BlockSuggestion.Kind = event.start <= now ? .insideBlock : .starting
            return (event, project, kind)
        }
        // Soonest-starting (or already-started) block wins when several qualify.
        guard let best = candidates.min(by: { $0.0.start < $1.0.start }) else { return nil }
        return BlockSuggestion(eventID: best.0.id, projectID: best.1.id,
                                projectName: best.1.name, endsAt: best.0.end, kind: best.2)
    }

    /// Matches an event to a project. Checked in order of confidence:
    /// 1. A learned exact title (the user previously answered "Switch", or
    ///    picked a project explicitly, for this exact event title).
    /// 2. Configured keywords (longest wins) — explicit and most precise.
    /// 3. The project's own name, or any of its words 4+ letters long,
    ///    whole-word / folded, so matching works without requiring a
    ///    keyword to be configured for every project.
    /// 4. The project's area name, as the widest, lowest-confidence fallback.
    static func matchProject(for event: KCalendarEvent,
                              projects: [CoachProject],
                              keywords: [UUID: [String]],
                              learnedEventTitles: [String: UUID] = [:]) -> CoachProject? {
        let foldedTitle = KTextFold.fold(event.title)

        if let learnedID = learnedEventTitles[foldedTitle],
           let learned = projects.first(where: { $0.id == learnedID }) {
            return learned
        }

        let haystack = foldedTitle
        var best: (project: CoachProject, keywordLength: Int)?
        func consider(_ term: String, _ project: CoachProject) {
            let folded = KTextFold.fold(term)
            guard !folded.isEmpty, containsWholeWord(folded, in: haystack) else { return }
            if best == nil || folded.count > best!.keywordLength {
                best = (project, folded.count)
            }
        }

        for project in projects {
            if let explicit = keywords[project.id], !explicit.isEmpty {
                explicit.forEach { consider($0, project) }
            } else {
                // No explicit keywords: the project's own name, and each of
                // its words 4+ letters long, are usable keywords on their
                // own — "Acme Relaunch" also matches on just "Relaunch".
                consider(project.name, project)
                for word in project.name.split(separator: " ") where word.count >= 4 {
                    consider(String(word), project)
                }
            }
        }
        if let best { return best.project }

        // Widest fallback: the project's area name (or a 4+-letter word of
        // it, same rule as the project name above), only when nothing more
        // specific matched anything.
        for project in projects {
            guard let area = project.areaName, !area.isEmpty else { continue }
            if containsWholeWord(KTextFold.fold(area), in: haystack) { return project }
            for word in area.split(separator: " ") where word.count >= 4 {
                if containsWholeWord(KTextFold.fold(String(word)), in: haystack) { return project }
            }
        }
        return nil
    }

    /// Today's upcoming (or in-progress) events that qualify for a
    /// suggestion by every rule EXCEPT having a project match — i.e. events
    /// the coach could not link to any project. The UI offers these as
    /// "Link this block to a project" once each (never repeats: pass
    /// `answeredEventIDs` exactly as for `suggest`).
    public static func unmatchedUpcomingEvents(now: Date,
                                                events: [KCalendarEvent],
                                                projects: [CoachProject],
                                                keywords: [UUID: [String]],
                                                leadMinutes: Int,
                                                answeredEventIDs: Set<String>,
                                                learnedEventTitles: [String: UUID] = [:]) -> [KCalendarEvent] {
        let leadSeconds = TimeInterval(max(0, leadMinutes) * 60)
        return events.filter { event in
            guard !event.isAllDay, !answeredEventIDs.contains(event.id) else { return false }
            guard event.end > now else { return false }
            let minutes = event.end.timeIntervalSince(event.start) / 60
            guard minutes >= Double(minimumEventMinutes) else { return false }
            let startsWithinLead = event.start <= now.addingTimeInterval(leadSeconds)
            let alreadyInside = event.start <= now && event.end > now
            guard startsWithinLead || alreadyInside else { return false }
            return matchProject(for: event, projects: projects, keywords: keywords,
                                learnedEventTitles: learnedEventTitles) == nil
        }
    }

    /// Whole-word containment: `needle` must appear in `haystack` bounded by
    /// non-letter/digit characters (or the string edges), so "PM" does not
    /// match inside "Sprint" and a short keyword cannot false-positive on a
    /// substring of an unrelated word.
    private static func containsWholeWord(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetter
                && !haystack[haystack.index(before: range.lowerBound)].isNumber
            let afterOK = range.upperBound == haystack.endIndex
                || !haystack[range.upperBound].isLetter && !haystack[range.upperBound].isNumber
            if beforeOK && afterOK { return true }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return false
    }
}
