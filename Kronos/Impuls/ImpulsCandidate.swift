// Kronos/Impuls/ImpulsCandidate.swift
// Everything that turns Core's deterministic `Candidate` list into what the Impuls card
// shows: the task lookup, the generic (offline) mentor line, and the empty-pool cascade.
// No AI here — see ImpulsMentor.swift for the crossfade seam.

import Foundation
import KronosCore

/// One fully-resolved card, ready to render. `mentorLine` starts as the deterministic
/// line and is the only field `ImpulsMentor` is allowed to replace later.
struct ImpulsCard: Identifiable {
    let task: KTask
    let mentorLine: String
    var id: UUID { task.id }
}

/// Why the pool has nothing to offer right now (spec §3.6) — each case is a full,
/// calm card of its own, never an error and never a blank view.
enum ImpulsEmptyReason {
    case noTasksYet          // store has never had a task
    case nothingOpen(doneToday: Int)   // everything is done
}

@MainActor
enum ImpulsQuery {
    /// Deterministic candidates for one energy level, widening the search rather than
    /// ever excluding untriaged work (rule: untriaged tasks are never excluded).
    /// `maxDeep` starts at `energy == .high` unless the caller forces it (the morning
    /// plan wants deep tasks IN the pool at any energy so its own "max 1 deep" diversity
    /// rule has something to diversify against); if the result is still empty, deep is
    /// allowed anyway before ever falling back to the empty state — an empty Impuls on a
    /// store that has open work is the exact bug the spec was amended to prevent.
    static func candidates(engine: RankingProviding,
                            energy: KEnergyLevel,
                            excluding excludedIDs: Set<UUID>,
                            tasks: [KTask],
                            today: Int,
                            count: Int,
                            forceDeep: Bool = false) -> [Candidate] {
        let wantsDeep = forceDeep || energy == .high
        var pool = engine.candidates(energy: energy, count: count + excludedIDs.count,
                                      maxDeep: wantsDeep, today: today, tasks: tasks)
            .filter { !excludedIDs.contains($0.taskID) }
        if pool.isEmpty && !wantsDeep {
            // Cascade: nothing shallow-eligible left, but deep tasks may still exist.
            pool = engine.candidates(energy: energy, count: count + excludedIDs.count,
                                      maxDeep: true, today: today, tasks: tasks)
                .filter { !excludedIDs.contains($0.taskID) }
        }
        return Array(pool.prefix(count))
    }

    static func emptyReason(tasks: [KTask], today: Int) -> ImpulsEmptyReason {
        if tasks.isEmpty { return .noTasksYet }
        let doneToday = tasks.filter {
            guard let d = $0.completedAt else { return false }
            return Day.from(d) == today
        }.count
        return .nothingOpen(doneToday: doneToday)
    }

    /// The offline mentor line (spec §3.5's `reason(...)`, adapted to the fields Core's
    /// `Candidate` actually carries). `RankingEngine.candidates` (Foundation-only, ships no
    /// strings) always returns one of exactly five fixed English shapes for `reason` — never
    /// re-glue Core's own architecture rule (spec §1) by giving it a language parameter (the
    /// same tradeoff KPlural.swift and TriageReasonLocalizer.swift document for their own
    /// fixed shapes); this call site localises the known shapes via the catalog and falls back
    /// to the raw string only for a shape this leaf does not recognise (never invented, always
    /// what Core actually said).
    static func genericMentorLine(for task: KTask, candidateReason: String, energy: KEnergyLevel) -> String {
        if task.dread { return String(localized: "impuls.fallback.dread") }
        if let localized = localizedCandidateReason(candidateReason) {
            return localized
        }
        switch energy {
        case .low:  return String(localized: "impuls.fallback.low")
        case .mid:  return String(localized: "impuls.fallback.mid")
        case .high: return String(localized: "impuls.fallback.high")
        }
    }

    /// One of RankingEngine's five fixed shapes -> its catalog translation, or nil for
    /// "Good energy match" (routes to the generic energy fallback, same as before this fix)
    /// or any string Core did not actually produce (never mistranslate a shape that does not
    /// exist).
    private static func localizedCandidateReason(_ reason: String) -> String? {
        switch reason {
        case "Nothing shallow left": return String(localized: "impuls.candidate.nothingshallow")
        case "Shallow, but you have been avoiding it": return String(localized: "impuls.candidate.dreadshallow")
        case "Shallow and quick": return String(localized: "impuls.candidate.shallowquick")
        case "Next by priority": return String(localized: "impuls.candidate.nextbypriority")
        case "Good energy match": return nil
        default: return reason.isEmpty ? nil : reason
        }
    }

    /// First move: stored value wins; otherwise Core's deterministic generator, which
    /// always yields a lint-passing move (spec §2.3) and never leaves the card without one.
    static func firstMove(for task: KTask, language: Lang) -> String {
        if let stored = task.firstMove, !stored.isEmpty { return stored }
        let hasOpenSubtask = task.nextOpenSubtask != nil
        return DeterministicFirstMove.generate(title: task.title,
                                                firstMoveURL: task.firstMoveURL,
                                                hasOpenSubtask: hasOpenSubtask,
                                                notesNonEmpty: !task.notes.isEmpty,
                                                dread: task.dread,
                                                language: language)
    }
}

extension KTask {
    /// Triage may fill `firstMoveURL` from notes (spec §2.4); the field is not yet on
    /// `KTask`'s contract, so this reads nil until Core adds it — never invented here.
    var firstMoveURL: String? { nil }
}

/// Persists the last chosen energy for today. A UserDefaults key, hermetic under
/// `KRONOS_SNAPSHOT` like every other UI-state write in the app (AppModel.persist() uses the
/// identical guard) so a snapshot run never touches the real preferences domain. Keyed by day
/// number, not just "last energy", so a value from yesterday never silently answers today's
/// question.
enum ImpulsEnergyMemory {
    private static let dayKey = "kronos.impuls.energy.day"
    private static let levelKey = "kronos.impuls.energy.level"

    private static var isHermetic: Bool { ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil }

    static func rememberToday(_ energy: KEnergyLevel) {
        guard !isHermetic else { return }
        let d = UserDefaults.standard
        d.set(Day.today(calendar: KronosLocale.calendar), forKey: dayKey)
        d.set(energy.rawValue, forKey: levelKey)
    }

    /// nil when nothing was remembered yet, or the stored day is not today.
    static func todayEnergy() -> KEnergyLevel? {
        guard !isHermetic else { return nil }
        let d = UserDefaults.standard
        guard d.object(forKey: dayKey) != nil, d.integer(forKey: dayKey) == Day.today(calendar: KronosLocale.calendar),
              d.object(forKey: levelKey) != nil else { return nil }
        return KEnergyLevel(rawValue: d.integer(forKey: levelKey))
    }
}
