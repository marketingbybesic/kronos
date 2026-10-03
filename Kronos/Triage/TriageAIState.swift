// Kronos/Triage/TriageAIState.swift. Split out of TriageFlowView.swift to keep that file
// under the 500-line lint gate, same reason TriageFieldMenus.swift was split out. The AI
// suggestion lifecycle for one triage card: load (neighbour vote + AI upgrade), Refresh/Retry,
// and the always-visible state row (asking/answered/failed).
import SwiftUI
import KronosCore

/// A calm, specific reason the AI upgrade did not land — never a raw error string on screen.
/// `modelUnavailable` covers the router's own silent
/// fallback path (every candidate failed, `AIRouter.swift:44-53`), which today is the only one
/// this app's concrete router can actually produce; the others read a thrown `AIError` for a
/// future/test router that does throw.
enum AIFailureReason: Equatable {
    case timeout, rateLimited, emptyAnswer, noKey, modelUnavailable

    init(_ error: Error) {
        switch error as? AIError {
        case .timeout: self = .timeout
        case .http(429): self = .rateLimited
        case .badJSON: self = .emptyAnswer
        case .http(401), .http(403), .noUsableProvider: self = .noKey
        default: self = .modelUnavailable
        }
    }

    var localizedText: String {
        switch self {
        case .timeout: String(localized: "triage.flow.ai.failed.timeout")
        case .rateLimited: String(localized: "triage.flow.ai.failed.ratelimited")
        case .emptyAnswer: String(localized: "triage.flow.ai.failed.emptyanswer")
        case .noKey: String(localized: "triage.flow.ai.failed.nokey")
        case .modelUnavailable: String(localized: "triage.flow.ai.failed.modelunavailable")
        }
    }
}

extension TriageFlowView {

    /// The one question every ask (first load, R, Retry) goes through: the card's AI switch is on,
    /// a router exists, and its privacy mode is not Off. With any of these false nothing is sent.
    var aiMayAsk: Bool {
        AICallPolicy.mayAsk(switchOn: aiEnabled, hasRouter: model.ai != nil, mode: (model.ai as? AIRouter)?.mode)
    }

    /// The always-visible AI state (brief line 22): asking with elapsed seconds, answered,
    /// failed with a calm reason + Retry, or nothing (AI off / never asked) — plus Refresh
    /// (key R), which re-asks at any time and never blocks the card's own keys (the ask runs
    /// off `handleKey`'s synchronous path entirely, same as the original load).
    @ViewBuilder
    var aiStateRow: some View {
        // AI off or no router: nothing at all (no dead Refresh button). Otherwise ONE line, ONE
        // button, never wrapped: the text truncates before a button label can break ("Ret ry").
        if aiEnabled, model.ai != nil {
            HStack(spacing: Space.x2) {
                if isAskingAI {
                    Text(String(format: String(localized: "triage.flow.asking"), askingElapsed))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                        .uiTestAnchor("triage.card.asking")
                } else if aiFailure == .noKey {
                    // "AI is not set up" is the one failure the person can fix: it opens Settings > AI.
                    Button { TriageSettingsLink.openAI() } label: {
                        HStack(spacing: Space.x1) {
                            Text(AIFailureReason.noKey.localizedText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Icon("chevron-right", size: Metrics.iconXS).accessibilityHidden(true)
                        }
                    }
                    .kButton(.ghost)
                    .accessibilityLabel(AIFailureReason.noKey.localizedText)
                    .accessibilityHint(String(localized: "triage.flow.ai.setup.hint"))
                    .uiTestAnchor("triage.card.ai.setup")
                } else if let aiFailure {
                    Text(aiFailure.localizedText)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .uiTestAnchor("triage.card.ai.failed")
                    // Retry is the same re-ask as Refresh (key R), so a failure shows it once, and
                    // not at all without a key: asking again cannot help until Settings has one.
                    aiButton("triage.flow.ai.retry", anchor: "triage.card.ai.retry")
                } else {
                    aiButton("triage.flow.ai.refresh", anchor: "triage.card.ai.refresh")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func aiButton(_ key: String, anchor: String) -> some View {
        Button(String(localized: String.LocalizationValue(key))) { retryAI() }
            .kButton(.ghost)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isAskingAI)
            .uiTestAnchor(anchor)
    }

    /// Synchronous neighbour vote first (renders instantly, same as Impuls/AutoTriage), then
    /// `model.ai?.triage` may upgrade it — never blocks the card, never swaps the task on
    /// screen, only the suggestion values once they arrive for the SAME task still on screen.
    /// G5 "AI prijedlozi" switch: off means neighbours only, so the AI call is skipped outright
    /// rather than fetched and discarded.
    func loadSuggestion() {
        // Sweep has no suggestion: the card is a decision about an old task, not missing data.
        guard let task = current, !isSweep, !isReview else {
            suggestion = nil; suggestionSource = nil; fillable = nil; isAskingAI = false; aiFailure = nil; askingElapsed = 0
            return
        }
        aiFailure = nil
        let today = Day.today(calendar: KronosLocale.calendar)
        let context = TriageContextBuilder.build(for: task.title, notes: task.notes, from: neighbours(excluding: task.id))
        // The neighbour vote is the fill-only base: any field already locked this card keeps
        // whatever value is already on `suggestion` (a hand-made pick, or a still-locked
        // earlier vote) instead of being clobbered by a fresh vote on every advance/version tick.
        let voted = NeighbourTriage.infer(title: task.title, notes: task.notes, context: context, today: today)
        suggestion = TriageSuggestionMerge.apply(voted, over: suggestion, respecting: lockedFields)
        suggestionSource = .neighbours
        // Only fields the vote really decided may be written; depth, estimate and energy stay
        // empty instead of taking the neutral placeholders a deterministic result carries.
        fillable = NeighbourTriage.fillableFields(title: task.title, notes: task.notes, context: context, today: today)
        guard aiMayAsk, let router = model.ai else { isAskingAI = false; return }
        askAI(for: task, today: today, context: context, router: router)
    }

    /// Refresh (key R / button): re-asks the model for the SAME card at any time, including
    /// after a failure. Never blocked by a stale in-flight call — `askID` below makes any
    /// earlier response for this task a no-op once a newer one has been requested.
    func retryAI() {
        // Refresh honours the Settings > AI switch: nothing leaves the Mac while it is off.
        guard aiMayAsk, !isSweep, !isReview, let task = current, let router = model.ai else { return }
        let today = Day.today(calendar: KronosLocale.calendar)
        let context = TriageContextBuilder.build(for: task.title, notes: task.notes, from: neighbours(excluding: task.id))
        askAI(for: task, today: today, context: context, router: router)
    }

    private func askAI(for task: KTask, today: Int, context: TriageContext, router: any AIRouting) {
        let taskID = task.id
        let projectNames = model.store.allProjects().map(\.name)
        let labelNames = model.store.labels().map(\.name)
        aiFailure = nil
        isAskingAI = true
        askingElapsed = 0
        askID = UUID()
        let thisAsk = askID
        let startedAt = Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard askID == thisAsk else { return }
                askingElapsed = Int(Date().timeIntervalSince(startedAt))
            }
        }
        Task { @MainActor in
            var thrown: Error?
            var reply: TriageResult?
            do {
                reply = try await router.triage(title: task.title, notes: task.notes,
                                                 projectNames: projectNames, labelNames: labelNames,
                                                 today: today, lockedFields: Set(lockedFields.map(\.rawValue)),
                                                 context: context)
            } catch {
                thrown = error
            }
            // The screen may have moved to a different card, switched the toggle off, or fired
            // a newer ask (Refresh) while this was in flight — any of those makes this reply a
            // no-op rather than a stale overwrite.
            guard askID == thisAsk, current?.id == taskID, aiEnabled else { return }
            if let thrown {
                // `AIRouting.triage` is declared `throws` but the concrete `AIRouter` never
                // actually throws (it already catches every provider failure and returns the
                // neighbour-vote fallback below) — this branch exists for a future/other
                // conforming router and for the FixtureAIClient-driven self-test that CAN
                // simulate a throw. Calm, specific reason — never a raw error string. The
                // neighbour vote already on screen stays; this only adds the failure line +
                // Retry.
                aiFailure = AIFailureReason(thrown)
            } else if let reply, reply.isDeterministic {
                // The router's OWN observable failure signal today: every provider hop failed
                // and it silently fell back to `NeighbourTriage.infer` (`version == 0`,
                // AIRouter.swift:44-53 `catch`) — indistinguishable from a real AI answer
                // without this check, which is exactly why a visible notice matters when the
                // model isn't actually answering. The fallback's own fields are still a valid
                // neighbour vote, so they are merged in as usual; only the state line changes.
                suggestion = TriageSuggestionMerge.apply(reply, over: suggestion, respecting: lockedFields)
                suggestionSource = .neighbours
                aiFailure = .modelUnavailable
            } else if let reply {
                suggestion = TriageSuggestionMerge.apply(reply, over: suggestion, respecting: lockedFields)
                suggestionSource = .ai
                aiFailure = nil
            }
            isAskingAI = false
            elapsedTimer?.invalidate()
        }
    }

    func neighbours(excluding id: UUID) -> [TriageExampleSource] {
        let now = Date()
        return model.store.allTasks().filter { $0.id != id && $0.deletedAt == nil }.map { t in
            let age = now.timeIntervalSince(t.updatedAt) / 86_400
            return TriageExampleSource(title: t.title, projectName: t.project?.name, priority: t.priority,
                                       effort: t.effort, depth: t.depth, dueDay: t.dueDay,
                                       open: t.status != .done, recency: 1 / (1 + max(0, age)))
        }
    }
}
