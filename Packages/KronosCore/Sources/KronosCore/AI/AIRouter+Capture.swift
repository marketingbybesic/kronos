// `AIRouter`'s two capture-feature methods: extracting tasks from a pasted note dump,
// and improving a task breakdown. Split out of AIRouter.swift, which is already close
// to the 500-line cap.
//
// `breakdown` never throws: the deterministic result is computed first and
// returned as-is on `AIMode.off`, on any transport error, or when the
// model's reply fails validation.
//
// `extractTasks` ALSO never throws to its own caller, but internally its validator DOES
// throw when a reply keeps zero tasks (see `ExtractOutlineValidator.validateExtractOutline`,
// ExtractOutlineValidator.swift): an empty-but-successfully-decoded reply would otherwise
// short-circuit `hopAcrossModels` into a silent, unlabelled "deterministic" result with no
// story for why. Every path out of `extractTasks` now carries an `ExtractReason`.
//
// The parsing/validation itself (`extractOutlineBlock`, the hallucination guard,
// `validateExtractOutline`) lives in `ExtractOutlineValidator.swift`, not here: those functions
// have no dependency on `AIRouter`'s own state, so splitting them out lets
// `scripts/extract-outline-parse.swift` (the capture-eval harness) compile and run the REAL
// validator directly instead of maintaining a hand-mirrored copy that can drift from it.

import Foundation

extension AIRouter {

    // MARK: - Extract

    public func extractTasks(from text: String,
                             projectNames: [String],
                             existingOpenTitles: [String],
                             today: Int) async -> ExtractResult {
        let deterministic = Self.markDuplicates(
            NoteSplitter.split(text, today: today, projectNames: projectNames),
            existingOpenTitles: existingOpenTitles)

        let droppedByCap = max(0, deterministic.count - NoteSplitter.maxProposals)
        func base(_ reason: ExtractReason) -> ExtractResult {
            ExtractResult(tasks: Array(deterministic.prefix(NoteSplitter.maxProposals)),
                         droppedLineCount: droppedByCap, isDeterministic: true, reason: reason)
        }

        guard mode != .off else { return base(.aiOff) }
        let eligible = eligibleCandidates
        guard !eligible.isEmpty else { return base(.noModel) }

        let language = detectLanguage(text)
        let system = TemplateFill.fill(PromptTemplates.extractSystem, [
            "HOUSE_RULES": HouseRulesRenderer.render(rules: houseRules, scope: .all, limit: 30),
            "LANG_NAME": language.name, "LANG": language.rawValue
        ])
        let user = TemplateFill.fill(PromptTemplates.extractUserTemplate, [
            "TODAY_ISO": Day.iso(today),
            "PROJECT_NAMES": projectNames.joined(separator: ", "),
            "LABEL_NAMES": "",
            "EXISTING_TITLES": existingOpenTitles.joined(separator: ", "),
            "NOTES_6000": PrivacyRedactor.sanitizeCapture(text)
        ])

        // Mirrors `hopAcrossModels`'s own loop (AIRouter.swift), but tracked locally rather than
        // through that shared helper: this needs to tell apart three outcomes
        // `hopAcrossModels`'s single `lastError` cannot distinguish for the caller — every
        // candidate transport-failed, every candidate answered EMPTY, or at least one answered
        // with content but the hallucination guard rejected everything — that distinction is
        // what `ExtractReason` reports.
        var rejectedCount = 0
        var sawEmptyReply = false
        var lastTransportError: AIError = .noUsableProvider
        for candidate in eligible {
            let request = AIRequest(model: candidate.client.modelID, messages: [.system(system), .user(user)],
                                    kind: .extract, maxTokens: AIBudget.maxTokens(for: .extract),
                                    budgetSeconds: AIBudget.seconds(for: .extract))
            let outline: String
            do {
                let response = try await candidate.client.send(request)
                try response.validated()
                outline = ExtractOutlineValidator.extractOutlineBlock(response.content)
            } catch let error as AIError {
                // Transport-level failure — the candidate never even answered. Never counted in
                // `rejectedCount`, which is reserved for "answered, decoded, guard kept nothing".
                lastTransportError = error
                if !error.shouldHop { break }
                continue
            } catch {
                lastTransportError = .badJSON(prefix: String(describing: error).prefix(200).description)
                continue
            }
            guard !outline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                sawEmptyReply = true
                continue
            }
            do {
                let tasks = try ExtractOutlineValidator.validateExtractOutline(
                    outline, sourceText: text, projectNames: projectNames, today: today)
                let marked = Self.markDuplicates(tasks, existingOpenTitles: existingOpenTitles)
                let capped = Array(marked.prefix(NoteSplitter.maxProposals))
                let dropped = max(0, marked.count - NoteSplitter.maxProposals)
                return ExtractResult(tasks: capped, droppedLineCount: dropped, isDeterministic: false,
                                     reason: .ai(model: candidate.client.modelID))
            } catch {
                // The candidate answered with real content but every task line was rejected by
                // the hallucination/priority/effort guards (`validateExtractOutline` always
                // throws on zero kept) — a genuine rejection, so the next candidate still gets a
                // turn (unlike a transport error's `shouldHop` gate above, a rejection always hops).
                rejectedCount += 1
                continue
            }
        }
        if rejectedCount > 0 { return base(.allRejected(rejectedCount)) }
        if sawEmptyReply { return base(.emptyAnswer) }
        return base(.transport(lastTransportError.description))
    }

    /// A proposal whose folded title matches an existing open task's folded
    /// title is marked, never filtered out — the user still sees it and can decide.
    static func markDuplicates(_ proposals: [ProposedTask], existingOpenTitles: [String]) -> [ProposedTask] {
        let foldedOpen = Set(existingOpenTitles.map(KTextFold.fold))
        return proposals.map { p in
            var p = p
            p.isDuplicateOfOpenTask = foldedOpen.contains(KTextFold.fold(p.title))
            return p
        }
    }

    // MARK: - Breakdown

    public func breakdown(title: String, notes: String, existingSubtasks: [String]) async -> BreakdownResult {
        let language = detectLanguage(title)
        let deterministic = DeterministicBreakdown.steps(title: title, notes: notes, language: language)

        guard mode != .off, !candidates.isEmpty else { return deterministic }

        let system = TemplateFill.fill(PromptTemplates.breakdownSystem, [
            "HOUSE_RULES": HouseRulesRenderer.render(rules: houseRules, scope: .all, limit: 30),
            "LANG_NAME": language.name, "LANG": language.rawValue
        ])
        let user = TemplateFill.fill(PromptTemplates.breakdownUserTemplate, [
            "TITLE": title, "NOTES_300": PrivacyRedactor.sanitizeNotes(notes), "EST": "30"
        ])
        let request = AIRequest(model: candidates.first?.client.modelID ?? "",
                                messages: [.system(system), .user(user)], kind: .breakdown)
        do {
            return try await hopAcrossModels(request, projectNames: [], labelNames: [],
                                             language: language) { data in
                try Self.validateBreakdown(data, existingSubtasks: existingSubtasks)
            }
        } catch {
            return deterministic
        }
    }

    /// 3-7 non-empty steps, none equal (folded) to a step already in
    /// `existingSubtasks` — the "never touches existing subtasks" guarantee
    /// starts here: an AI reply that merely repeats what is already there is
    /// treated as unusable and falls back, exactly like an invalid one.
    static func validateBreakdown(_ data: Data, existingSubtasks: [String]) throws -> BreakdownResult {
        let decoded: BreakdownWire
        do { decoded = try JSONDecoder().decode(BreakdownWire.self, from: data) }
        catch { throw AIError.badJSON(prefix: String(decoding: data.prefix(200), as: UTF8.self)) }

        let nonEmpty = decoded.subtasks.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard (3...7).contains(nonEmpty.count) else {
            throw AIError.badJSON(prefix: "subtasks count out of range")
        }
        let foldedExisting = Set(existingSubtasks.map(KTextFold.fold))
        guard !nonEmpty.contains(where: { foldedExisting.contains(KTextFold.fold($0)) }) else {
            throw AIError.badJSON(prefix: "subtask duplicates an existing one")
        }
        guard !decoded.firstMove.isEmpty else {
            throw AIError.badJSON(prefix: "firstMove empty")
        }
        return BreakdownResult(subtasks: nonEmpty, firstMove: decoded.firstMove, isDeterministic: false)
    }
}
