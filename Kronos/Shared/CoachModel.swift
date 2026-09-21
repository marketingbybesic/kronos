// UI_CONTRACT_REV 5 — the coach's app-side state. Driver-owned; screens read and call it, they do
// not reimplement it. Reached as `model.coach`.
//   - settings            CoachSettings (persisted; hermetic under KRONOS_SNAPSHOT)
//   - presets             active Ordo preset per scope; applying one = setting that scope's
//                         ViewOptions, so list, Now card, sidebar tint and menu bar all follow
//   - block coach         today's calendar blocks, the current Switch / Stay suggestion, answers,
//                         "this block is for..." learning
// Calendar access is NEVER requested from here: only an explicit button in Settings asks. Without
// access every block feature is simply empty and the UI shows a calm "Allow access" row.
import Foundation
import Observation
import KronosCore

@MainActor
@Observable
final class CoachModel {
    private unowned let model: AppModel
    private let store: CoachSettingsStore
    private let calendar: any CalendarProviding
    private let stateKey = "kronos.coach.blockstate.v1"
    private let defaults: UserDefaults

    private(set) var settings: CoachSettings
    /// The one block suggestion worth showing right now (nil = stay silent).
    private(set) var blockSuggestion: BlockSuggestion?
    /// Today's timed events with the project each one maps to (nil = not linked yet).
    private(set) var todaysBlocks: [(event: KCalendarEvent, projectID: UUID?)] = []
    private(set) var calendarAccess: KCalendarAccess = .notDetermined
    private var blockState: BlockCoachState

    init(model: AppModel, calendar: (any CalendarProviding)? = nil) {
        self.model = model
        // Snapshot runs get a throwaway domain: they never read or write real user preferences.
        let env = ProcessInfo.processInfo.environment
        let hermetic = env["KRONOS_SNAPSHOT"] != nil || env["KRONOS_STORE_DIR"] != nil || env["KRONOS_UITEST"] != nil
        // A live UI test run (KRONOS_STORE_DIR / KRONOS_UITEST) or a snapshot run must never
        // construct the real EventKit bridge: EventKit shows a real macOS permission prompt on
        // first touch, which would hang a headless/automated run waiting on a dialog nobody can
        // answer. FixtureCalendar (Core) is a no-op double: `.notDetermined`, no events — exactly
        // what a fresh install looks like before access is granted.
        self.calendar = calendar ?? (hermetic ? FixtureCalendar(authorizationStatus: .notDetermined) : EventKitCalendar())
        let d = hermetic ? (UserDefaults(suiteName: "kronos.snapshot." + UUID().uuidString) ?? .standard) : .standard
        self.defaults = d
        self.store = CoachSettingsStore(defaults: d)
        self.settings = store.load()
        let today = Day.today()
        if let data = d.data(forKey: stateKey), let s = try? JSONDecoder().decode(BlockCoachState.self, from: data) {
            self.blockState = s.rolledOver(to: today)
        } else {
            self.blockState = BlockCoachState(day: today)
        }
    }

    // MARK: Settings

    func update(_ mutate: (inout CoachSettings) -> Void) {
        var s = settings
        mutate(&s)
        guard s != settings else { return }
        settings = s
        store.save(s)
    }

    // MARK: Ordo presets

    var presets: [OrdoPreset] { settings.presets }

    func activePreset(for scope: ListScope) -> OrdoPreset {
        OrdoPresetResolver.preset(for: scope.storageKey, settings: settings)
    }

    /// Switching a preset rewrites that scope's sort + filter. One mechanism: everything that
    /// already follows ViewOptions (list order, Now card, Ordo, menu bar) follows the preset.
    func applyPreset(_ id: String, to scope: ListScope) {
        guard let preset = settings.presets.first(where: { $0.id == id }) else { return }
        update { $0.defaultPresetByScope[scope.storageKey] = id }
        var options = model.options(for: scope)
        options.sort = OrdoPresetResolver.sort(for: preset)
        options.filter = OrdoPresetResolver.filter(for: preset)
        model.setOptions(options, for: scope)
        model.didMutate()
    }

    // MARK: Block coach

    /// Call on launch, on wake, every minute while the app runs, and after any answer.
    func refreshBlocks(now: Date = Date()) async {
        calendarAccess = calendar.authorizationStatus
        guard settings.blockCoachEnabled, calendarAccess == .granted else {
            blockSuggestion = nil
            todaysBlocks = []
            return
        }
        blockState = blockState.rolledOver(to: Day.today())
        let cal = Foundation.Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
        // The user's calendar selection (Settings > Coach); nothing selected yet = all calendars.
        var ids = defaults.selectedCalendarIDs()
        if ids.isEmpty { ids = await calendar.calendars().map(\.id) }
        let events = await calendar.events(from: start, to: end, in: ids)
        let projects = coachProjects()
        let focusProject = model.focusTaskID.flatMap { model.store.task($0) }?.project?.id

        blockSuggestion = BlockCoach.suggest(now: now, events: events, projects: projects,
                                             keywords: settings.calendarKeywords,
                                             leadMinutes: settings.blockLeadMinutes,
                                             focusProjectID: focusProject,
                                             answeredEventIDs: blockState.answeredEventIDs,
                                             learnedEventTitles: settings.learnedEventTitles)
        let unmatched = Set(BlockCoach.unmatchedUpcomingEvents(
            now: start, events: events, projects: projects, keywords: settings.calendarKeywords,
            leadMinutes: 24 * 60, answeredEventIDs: [],
            learnedEventTitles: settings.learnedEventTitles).map(\.id))
        todaysBlocks = events.filter { !$0.isAllDay }.sorted { $0.start < $1.start }.map { event in
            (event, unmatched.contains(event.id) ? nil : matchedProject(for: event, projects: projects))
        }
    }

    /// "Switch": open that project's list (Ordo follows) and remember the answer.
    func switchToBlock() {
        guard let s = blockSuggestion else { return }
        model.scope = .project(s.projectID)
        model.pinnedFocusTaskID = nil
        answer(s.eventID)
        model.persist()
        model.didMutate()
    }

    /// "Stay" is a respected answer: silent for the rest of this block.
    func stayInCurrent() {
        guard let s = blockSuggestion else { return }
        answer(s.eventID)
    }

    /// "This block is for..." teaches the link once; it is matched automatically from then on.
    func link(eventTitle: String, to projectID: UUID) {
        update { $0.learn(eventTitle: eventTitle, projectID: projectID) }
        Task { await refreshBlocks() }
    }

    func forgetLearnedLink(eventTitle: String) {
        update { $0.learnedEventTitles[eventTitle] = nil }
        Task { await refreshBlocks() }
    }

    /// Only ever called from an explicit "Allow calendar access" button.
    func requestCalendarAccess() async {
        calendarAccess = await calendar.requestAccess()
        await refreshBlocks()
    }

    // MARK: Private

    private func answer(_ eventID: String) {
        blockState = blockState.answering(eventID)
        if let data = try? JSONEncoder().encode(blockState) { defaults.set(data, forKey: stateKey) }
        blockSuggestion = nil
    }

    private func coachProjects() -> [CoachProject] {
        model.store.allProjects(includeArchived: false).map {
            CoachProject(id: $0.id, name: $0.name, areaName: $0.area?.name)
        }
    }

    private func matchedProject(for event: KCalendarEvent, projects: [CoachProject]) -> UUID? {
        // Ask the coach itself with an impossible focus so a match always yields a suggestion.
        BlockCoach.suggest(now: event.start, events: [event], projects: projects,
                           keywords: settings.calendarKeywords, leadMinutes: 0, focusProjectID: nil,
                           answeredEventIDs: [], learnedEventTitles: settings.learnedEventTitles)?.projectID
    }
}
