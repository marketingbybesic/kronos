// Coach/OrdoPreset.swift — named, editable Ordo
// logic. A preset is a plain value the app turns into a scope's sort +
// filter (`ViewOptions` in Kronos/Shared/UIContract.swift, read-only
// reference — this file never imports app code and exposes only Core types).

import Foundation

/// One reusable ordering: a name, a multi-key sort, an optional filter, and
/// whether the list should additionally be re-ranked by `RankingEngine`
/// (the `coach` built-in) rather than sorted alone.
public struct OrdoPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// A localisation key for a built-in (e.g. "ordo.preset.deadline"), or a
    /// literal name typed by the user for a custom preset. The two are
    /// distinguished by `isBuiltIn`, not by string shape.
    public var name: String
    public var sort: [KSortDescriptor]
    public var filter: KFilter
    public var usesCoachRanking: Bool
    public var energy: KEnergyLevel?

    public init(id: String,
                name: String,
                sort: [KSortDescriptor],
                filter: KFilter = .empty,
                usesCoachRanking: Bool = false,
                energy: KEnergyLevel? = nil) {
        self.id = id
        self.name = name
        self.sort = sort
        self.filter = filter
        self.usesCoachRanking = usesCoachRanking
        self.energy = energy
    }

    /// True for one of the five stable built-in ids; a custom preset the
    /// user created gets any other id (a UUID string in practice).
    public var isBuiltIn: Bool { Self.builtInIDs.contains(id) }

    // MARK: Built-ins (stable ids — persisted in CoachSettings.defaultPresetByScope)

    public static let deadlineID  = "deadline"
    public static let quickwinsID = "quickwins"
    public static let deepworkID  = "deepwork"
    public static let priorityID  = "priority"
    public static let coachID     = "coach"

    private static let builtInIDs: Set<String> = [deadlineID, quickwinsID, deepworkID, priorityID, coachID]

    /// Deadline first: earliest due date, ties broken by priority (highest first).
    public static let deadline = OrdoPreset(
        id: deadlineID, name: "ordo.preset.deadline",
        sort: [.asc(.deadline), .desc(.priority)])

    /// Quick wins: smallest effort first, then earliest deadline — the "clear
    /// the small stuff" preset for low-energy moments.
    public static let quickwins = OrdoPreset(
        id: quickwinsID, name: "ordo.preset.quickwins",
        sort: [.asc(.effort), .asc(.deadline)])

    /// Deep work: deep-attention tasks first, then largest effort first (the
    /// biggest, most demanding block of work leads the list).
    public static let deepwork = OrdoPreset(
        id: deepworkID, name: "ordo.preset.deepwork",
        sort: [.desc(.depth), .desc(.effort)])

    /// Straight priority order, deadline as the tiebreak.
    public static let priority = OrdoPreset(
        id: priorityID, name: "ordo.preset.priority",
        sort: [.desc(.priority), .asc(.deadline)])

    /// `RankingEngine`'s own ordering at the chosen (or default) energy level.
    /// `sort` is still populated as the fallback a caller uses if it chooses
    /// not to invoke the ranking engine (e.g. an unranked secondary view).
    public static let coach = OrdoPreset(
        id: coachID, name: "ordo.preset.coach",
        sort: [.desc(.priority), .asc(.deadline)],
        usesCoachRanking: true, energy: .mid)

    public static let builtIns: [OrdoPreset] = [deadline, quickwins, deepwork, priority, coach]
}

/// Resolves which preset applies to a given scope, and turns a preset into
/// the plain sort + filter values `ViewOptions` carries.
public enum OrdoPresetResolver {

    /// The preset for `scopeKey`: the user's chosen default if set and still
    /// present in `settings.presets`, else the `priority` built-in — a
    /// steady, unsurprising order rather than picking an implicit favourite.
    public static func preset(for scopeKey: String, settings: CoachSettings) -> OrdoPreset {
        if let id = settings.defaultPresetByScope[scopeKey],
           let match = settings.presets.first(where: { $0.id == id }) {
            return match
        }
        return settings.presets.first { $0.id == OrdoPreset.priorityID } ?? OrdoPreset.priority
    }

    /// The sort a list should apply for this preset. When `usesCoachRanking`
    /// is true the caller is expected to rank via `RankingEngine` instead and
    /// use this only as a fallback ordering (e.g. while AI/ranking is
    /// unavailable) — never both at once.
    public static func sort(for preset: OrdoPreset) -> [KSortDescriptor] { preset.sort }

    /// The filter a list should apply for this preset. Most built-ins add no
    /// filter (`.empty`) — they only reorder — but a custom preset may narrow
    /// the list as well.
    public static func filter(for preset: OrdoPreset) -> KFilter { preset.filter }
}
