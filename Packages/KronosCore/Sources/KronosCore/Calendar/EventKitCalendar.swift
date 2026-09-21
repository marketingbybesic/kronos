// The ONLY file in KronosCore that imports EventKit (G-L9.2, G3). Wrapped in
// #if canImport(EventKit) so the package still builds on a toolchain/platform
// without it; on macOS this is always available, the guard exists so a
// missing framework fails softly rather than breaking `swift build` for the
// other five leaves sharing this package.
//
// tech-stack.md §7: modern-only auth. `requestAccess(to:)` is deprecated and
// silently denies on macOS 14+; only `requestFullAccessToEvents()` is used.
// Never called except from `requestAccess()` — G-L9.1 requires zero TCC
// prompts before the user opts in.

#if canImport(EventKit)
import EventKit
import Foundation

@MainActor
public final class EventKitCalendar: CalendarProviding {
    private let store = EKEventStore()

    public init() {}

    public var authorizationStatus: KCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied // .denied, .restricted, .writeOnly, and any future case
        }
    }

    @discardableResult
    public func requestAccess() async -> KCalendarAccess {
        if authorizationStatus != .notDetermined { return authorizationStatus }
        do {
            let granted = try await store.requestFullAccessToEvents()
            return granted ? .granted : .denied
        } catch {
            return .denied // never throws out of the protocol (G3)
        }
    }

    public func calendars() async -> [KCalendarInfo] {
        guard authorizationStatus == .granted else { return [] }
        return store.calendars(for: .event).map {
            KCalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                          colorHex: $0.cgColor.map(Self.hex) ?? "#8E8E93",
                          sourceTitle: $0.source.title)
        }
    }

    public func events(from: Date, to: Date, in calendarIDs: [String]) async -> [KCalendarEvent] {
        guard authorizationStatus == .granted, !calendarIDs.isEmpty else { return [] }
        let idSet = Set(calendarIDs)
        let cals = store.calendars(for: .event).filter { idSet.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        return store.events(matching: predicate).map {
            KCalendarEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "",
                           start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay,
                           calendarID: $0.calendar.calendarIdentifier)
        }
    }

    private static func hex(_ color: CGColor) -> String {
        guard let c = color.components, c.count >= 3 else { return "#8E8E93" }
        let r = Int((c[0] * 255).rounded()), g = Int((c[1] * 255).rounded()), b = Int((c[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
#endif
