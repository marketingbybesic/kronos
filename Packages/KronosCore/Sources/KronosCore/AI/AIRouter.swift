// `AIRouter` is the sole `AIRouting` implementation: it renders prompts,
// walks the fallback chain `claude-sonnet-5 -> gpt-6-astra -> deterministic`,
// applies strict validation to every DTO, and never leaves a feature
// with nothing to render. `AIMode.off` short-circuits to the deterministic
// path before any client is touched.

import Foundation

/// One candidate in the fallback chain: a client plus the human-readable
/// model id used only for logging.
public struct AIRoutedCandidate: Sendable {
    public let client: any AIClient
    public init(client: any AIClient) { self.client = client }
}

/// The default `AIRouting` implementation.
///
/// `candidates` is the fallback chain in order; `mode == .off` means the
/// network is never touched regardless of what the chain contains — this is
/// the one hard invariant the `aiModeOffNeverTouchesTheNetwork` gate checks.
public struct AIRouter: AIRouting {
    public let mode: AIMode
    public let candidates: [AIRoutedCandidate]
    public let houseRules: [HouseRule]

    public init(mode: AIMode, candidates: [AIRoutedCandidate], houseRules: [HouseRule] = []) {
        self.mode = mode
        self.candidates = candidates
        self.houseRules = houseRules
    }

    // MARK: - Triage

    public func triage(title: String,
                       notes: String,
                       projectNames: [String],
                       labelNames: [String],
                       today: Int,
                       lockedFields: Set<String>,
                       context: TriageContext = .empty) async throws -> TriageResult {
        let language = detectLanguage(title)
        do {
            return try await triageOnce(title: title, notes: notes, projectNames: projectNames,
                                        labelNames: labelNames, today: today, language: language,
                                        context: context)
        } catch {
            // The neighbour vote replaces a context-blind deterministic fallback: the
            // last resort now reasons from the same examples the prompt would have
            // carried.
            return NeighbourTriage.infer(title: title, notes: notes, context: context, today: today)
        }
    }

    private func triageOnce(title: String, notes: String, projectNames: [String],
                            labelNames: [String], today: Int, language: Lang,
                            context: TriageContext) async throws -> TriageResult {
        let system = TemplateFill.fill(PromptTemplates.triageSystem, [
            "HOUSE_RULES": HouseRulesRenderer.render(rules: houseRules, scope: .triage, limit: 30),
            "LANG_NAME": language.name, "LANG": language.rawValue
        ])
        let user = TemplateFill.fill(PromptTemplates.triageUserTemplate, [
            "TODAY_ISO": Day.iso(today),
            "WEEKDAY": weekdayName(today),
            "PROJECT_NAMES": projectNames.joined(separator: ", "),
            "LABEL_NAMES": labelNames.joined(separator: ", "),
            "EXAMPLES": PromptTemplates.examplesBlock(context.promptLines),
            "TITLE": title,
            "NOTES_300": PrivacyRedactor.sanitizeNotes(notes)
        ])
        let request = AIRequest(model: candidates.first?.client.modelID ?? "",
                                messages: [.system(system), .user(user)], kind: .triage)
        return try await hopAcrossModels(request, projectNames: projectNames, labelNames: labelNames,
                                         language: language) { data in
            try Self.validateTriage(data, projectNames: projectNames, labelNames: labelNames, today: today)
        }
    }

    /// `candidates` filtered by `mode`. `.off` is handled by the `guard` at the top of
    /// `hopAcrossModels` before this is ever evaluated, so it only has to decide between
    /// the other two modes:
    /// `.privateOnly` keeps only `.onDevice`/`.zeroRetention` candidates
    /// (`privateOnlyAcceptsOnDevice`); `.allowAny` keeps the whole chain.
    var eligibleCandidates: [AIRoutedCandidate] {
        switch mode {
        case .off:         return []
        case .privateOnly: return candidates.filter { $0.client.dataPolicy == .onDevice || $0.client.dataPolicy == .zeroRetention }
        case .allowAny:    return candidates
        }
    }

    /// Rebuilds the request per candidate model id, since `AIRequest.model`
    /// is fixed at construction but each hop targets a different model.
    ///
    /// Internal rather than `private`: `AIRouter+Capture.swift` calls this from an
    /// extension in a separate file, the same reason `TaskStore`'s undo plumbing is
    /// `internal` rather than `private`.
    func hopAcrossModels<T>(_ template: AIRequest,
                                    projectNames: [String],
                                    labelNames: [String],
                                    language: Lang,
                                    validate: @escaping (Data) throws -> T) async throws -> T {
        guard mode != .off else { throw AIError.noUsableProvider }
        let eligible = eligibleCandidates
        guard !eligible.isEmpty else { throw AIError.noUsableProvider }
        var lastError: Error = AIError.noUsableProvider
        for candidate in eligible {
            let request = AIRequest(model: candidate.client.modelID, messages: template.messages,
                                    kind: template.kind, maxTokens: template.maxTokens,
                                    temperature: template.temperature, budgetSeconds: template.budgetSeconds)
            do {
                let response = try await candidate.client.send(request)
                try response.validated()
                let sliced = OutputExtraction.braceSlice(OutputExtraction.stripFences(response.content))
                guard let slicedData = sliced.data(using: .utf8) else {
                    throw AIError.badJSON(prefix: String(response.content.prefix(200)))
                }
                return try validate(slicedData)
            } catch {
                lastError = error
                if let aiError = error as? AIError, !aiError.shouldHop { break }
                continue
            }
        }
        throw lastError
    }

    static func validateTriage(_ data: Data, projectNames: [String], labelNames: [String], today: Int) throws -> TriageResult {
        let decoded: TriageResult
        do { decoded = try JSONDecoder().decode(TriageResult.self, from: data) }
        catch { throw AIError.badJSON(prefix: String(decoding: data.prefix(200), as: UTF8.self)) }

        guard decoded.firstMove.count <= 100 else {
            throw AIError.badJSON(prefix: "firstMove too long")
        }
        guard !decoded.firstMove.isEmpty else {
            throw AIError.badJSON(prefix: "firstMove empty")
        }
        let priority = max(0, min(4, decoded.priority))
        // §5.2's rule for estimateMinutes out of range is to drop the value, but
        // `TriageResult.estimateMinutes` is a non-optional Int — clamping is the
        // compatible reading of the same rule for a non-optional field.
        let estimate = max(1, min(480, decoded.estimateMinutes))
        let project = decoded.project.flatMap { p in
            projectNames.first { $0.caseInsensitiveCompare(p) == .orderedSame }
        }
        let labels = decoded.labels.filter { l in labelNames.contains { $0.caseInsensitiveCompare(l) == .orderedSame } }
        let due = decoded.due.flatMap { s -> String? in
            guard let day = Day.parseISO(s), day >= today else { return nil }
            return s
        }
        let reason = decoded.reason.map { String($0.prefix(90)) }
        return TriageResult(project: project, priority: priority, due: due, depth: decoded.depth,
                            estimateMinutes: estimate, energyKind: decoded.energyKind,
                            firstMove: decoded.firstMove, labels: labels, rationale: decoded.rationale,
                            proposedRule: decoded.proposedRule, effort: decoded.effort, reason: reason,
                            version: 1)
    }


    // MARK: - Retriage

    public func retriage(title: String, notes: String, previous: TriageResult, feedback: String,
                         projectNames: [String], labelNames: [String], today: Int) async throws -> TriageResult {
        let language = detectLanguage(title)
        let system = TemplateFill.fill(PromptTemplates.retriageSystem, [
            "HOUSE_RULES": HouseRulesRenderer.render(rules: houseRules, scope: .triage, limit: 30),
            "LANG_NAME": language.name, "LANG": language.rawValue
        ])
        let baseUser = TemplateFill.fill(PromptTemplates.triageUserTemplate, [
            "TODAY_ISO": Day.iso(today), "WEEKDAY": weekdayName(today),
            "PROJECT_NAMES": projectNames.joined(separator: ", "),
            "LABEL_NAMES": labelNames.joined(separator: ", "),
            "TITLE": title, "NOTES_300": PrivacyRedactor.sanitizeNotes(notes)
        ])
        let previousJSON = (try? String(decoding: JSONEncoder().encode(previous), as: UTF8.self)) ?? "{}"
        let addendum = TemplateFill.fill(PromptTemplates.retriageUserAddendumTemplate, [
            "PREVIOUS_JSON": previousJSON, "USER_FEEDBACK": PrivacyRedactor.redact(feedback)
        ])
        let user = baseUser + addendum
        let request = AIRequest(model: candidates.first?.client.modelID ?? "",
                                messages: [.system(system), .user(user)], kind: .retriage)
        do {
            return try await hopAcrossModels(request, projectNames: projectNames, labelNames: labelNames,
                                             language: language) { data in
                try Self.validateTriage(data, projectNames: projectNames, labelNames: labelNames, today: today)
            }
        } catch {
            return previous   // deterministic fallback: unchanged, no rule (spec §5)
        }
    }

    // MARK: - Impuls pick

    public func impulsPick(candidates impulsCandidates: [Candidate], energy: KEnergyLevel,
                           language: String) async throws -> ImpulsRanking {
        let lang: Lang = language == "hr" ? .hr : .en
        guard !impulsCandidates.isEmpty else { return ImpulsRanking(ranked: []) }
        let system = TemplateFill.fill(PromptTemplates.impulsPickSystem, [
            "HOUSE_RULES": HouseRulesRenderer.render(rules: houseRules, scope: .impuls, limit: 15),
            "LANG_NAME": lang.name, "LANG": lang.rawValue
        ])
        let lines = impulsCandidates.enumerated().map { i, c in "\(i + 1). \(c.reason)" }.joined(separator: "\n")
        let user = TemplateFill.fill(PromptTemplates.impulsPickUserTemplate, [
            "ENERGY": energyWire(energy), "TIME": "", "NEXT_EVENT_OR_NONE": "none",
            "CANDIDATE_LINES": lines
        ])
        let request = AIRequest(model: candidates.first?.client.modelID ?? "",
                                messages: [.system(system), .user(user)], kind: .impulsPick)
        return try await hopAcrossModels(request, projectNames: [], labelNames: [], language: lang) { data in
            let decoded: ImpulsRanking
            do { decoded = try JSONDecoder().decode(ImpulsRanking.self, from: data) }
            catch { throw AIError.badJSON(prefix: String(decoding: data.prefix(200), as: UTF8.self)) }
            guard decoded.isValid(candidateCount: impulsCandidates.count) else {
                throw AIError.badJSON(prefix: "invalid ranking permutation")
            }
            return decoded
        }
    }

    // MARK: - Ordo resort (RESERVED, no alpha caller — see AIDTOs.swift)

    public func ordoResort(queueTitles: [String], message: String, history: [String],
                           language: String) async throws -> OrdoResort {
        let lang: Lang = language == "hr" ? .hr : .en
        guard !queueTitles.isEmpty else { return OrdoResort.unchanged(queueCount: 0) }
        let system = TemplateFill.fill(PromptTemplates.ordoResortSystem, [
            "HOUSE_RULES": HouseRulesRenderer.render(rules: houseRules, scope: .ordo, limit: 30),
            "LANG_NAME": lang.name, "LANG": lang.rawValue
        ])
        let queueLines = queueTitles.enumerated().map { i, t in "\(i + 1). \(t)" }.joined(separator: "\n")
        let user = TemplateFill.fill(PromptTemplates.ordoResortUserTemplate, [
            "ENERGY": "mid", "TIME": "", "NEXT_EVENT_OR_NONE": "none",
            "QUEUE_LINES": queueLines, "HISTORY": history.joined(separator: "\n"), "MESSAGE": message
        ])
        let request = AIRequest(model: candidates.first?.client.modelID ?? "",
                                messages: [.system(system), .user(user)], kind: .ordoResort)
        do {
            return try await hopAcrossModels(request, projectNames: [], labelNames: [], language: lang) { data in
                let decoded: OrdoResort
                do { decoded = try JSONDecoder().decode(OrdoResort.self, from: data) }
                catch { throw AIError.badJSON(prefix: String(decoding: data.prefix(200), as: UTF8.self)) }
                guard decoded.isValid(queueCount: queueTitles.count) else {
                    throw AIError.badJSON(prefix: "not a permutation")
                }
                return decoded
            }
        } catch {
            return OrdoResort.unchanged(queueCount: queueTitles.count)
        }
    }

    // MARK: - Helpers

    private func weekdayName(_ day: Int) -> String {
        let date = Day.date(day)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func energyWire(_ e: KEnergyLevel) -> String {
        switch e { case .low: return "low"; case .mid: return "mid"; case .high: return "high" }
    }
}
