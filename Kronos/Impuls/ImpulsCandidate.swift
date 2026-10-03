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
                            forceDeep: Bool = false,
                            dreadServing: DreadServing? = nil) -> [Candidate] {
        let wantsDeep = forceDeep || energy == .high
        // An agent proposal waiting for review is never offered, whichever engine ranks: the
        // concrete engine skips it already, an injected one might not.
        let pending = Set(tasks.lazy.filter { $0.reviewRaw == NextEligibility.reviewPending }.map(\.id))
        let skipped = excludedIDs.union(pending)
        func ranked(maxDeep: Bool) -> [Candidate] {
            let want = count + skipped.count
            // The dread memory only exists on the concrete engine; a test double ranks without it.
            let all = (engine as? RankingEngine)
                .map { $0.candidates(energy: energy, count: want, maxDeep: maxDeep, today: today,
                                     tasks: tasks, dreadServing: dreadServing) }
                ?? engine.candidates(energy: energy, count: want, maxDeep: maxDeep, today: today, tasks: tasks)
            return all.filter { !skipped.contains($0.taskID) }
        }
        var pool = ranked(maxDeep: wantsDeep)
        if pool.isEmpty && !wantsDeep {
            // Cascade: nothing shallow-eligible left, but deep tasks may still exist.
            pool = ranked(maxDeep: true)
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

    /// One of RankingEngine's fixed shapes -> its catalog translation, or nil for
    /// "Good energy match" (routes to the generic energy fallback, same as before this fix)
    /// or any string Core did not actually produce (never mistranslate a shape that does not
    /// exist).
    private static func localizedCandidateReason(_ reason: String) -> String? {
        switch reason {
        case "Nothing shallow left": return String(localized: "impuls.candidate.nothingshallow")
        case "Shallow and quick": return String(localized: "impuls.candidate.shallowquick")
        case "Next by priority": return ""   // default ranking says nothing: the card hides the line
        case "Good energy match": return nil
        default: return reason.isEmpty ? nil : reason
        }
    }

    /// What a card shows as its first move. Same precedence as the inspector, the Now card and the
    /// menu bar: an open step, then an attachment, then a stored (non-generic) move; only when none
    /// exists does Core's deterministic generator speak. A generic result makes the title the hero.
    static func hero(for task: KTask, language: Lang) -> ImpulsDefaults.Hero {
        let move: String
        switch FirstMoveLogic.display(for: task) {
        case .fromSubtask(let title): move = title
        case .fromAttachment(let suggestion): move = suggestion.localized
        case .editable(let text, _):
            move = text ?? DeterministicFirstMove.generate(title: task.title, firstMoveURL: nil,
                                                           hasOpenSubtask: false,
                                                           notesNonEmpty: !task.notes.isEmpty,
                                                           dread: task.dread, language: language,
                                                           titleLanguageWins: false)
        }
        return ImpulsDefaults.hero(move: move, moveIsGeneric: DeterministicFirstMove.isGenericTemplate(move), title: task.title)
    }

    /// The link Start opens when the first move came from an attachment: an email, else a file or
    /// folder, else a note or web page (the order FirstMoveLogic uses). nil for any other first move.
    static func firstMoveLink(for task: KTask) -> ContextLink? {
        guard case .fromAttachment = FirstMoveLogic.display(for: task) else { return nil }
        let links = ContextLink.findAll(in: task.notes)
        return links.first { $0.kind == .email }
            ?? links.first { $0.kind == .file || $0.kind == .folder }
            ?? links.first { $0.kind == .appleNote || $0.kind == .web }
    }
}
