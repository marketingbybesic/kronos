import Testing
import Foundation
@testable import KronosCore

private let triageReply = """
{"project":null,"priority":2,"due":null,"depth":"shallow","estimateMinutes":15,
 "energyKind":"admin","firstMove":"Open the invoice folder and find September.","labels":[],
 "rationale":"One document and one email, no preparation needed."}
"""

/// The whole triage chain stops at its cap, whatever the models are doing.
struct TriageChainCapTests {

    private func triage(_ router: AIRouter) async throws -> TriageResult {
        try await router.triage(title: "Send the invoice", notes: "", projectNames: [], labelNames: [],
                                today: 20_000, lockedFields: [], context: .empty)
    }

    @Test func theCapIsFifteenSeconds() {
        #expect(AIBudget.triageChainSeconds == 15)
        let router = AIRouter(mode: .allowAny, candidates: [])
        #expect(router.chainBudgetSeconds == 15)
    }

    @Test func aStalledChainReturnsTheNeighbourVoteAtTheCap() async throws {
        // Two hops that would each take 30 s; the cap is 0.4 s.
        let slowA = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageReply)], delay: .seconds(30))
        let slowB = FixtureAIClient(modelID: "gpt-6-astra", script: [.content(triageReply)], delay: .seconds(30))
        let router = AIRouter(mode: .allowAny,
                              candidates: [AIRoutedCandidate(client: slowA), AIRoutedCandidate(client: slowB)],
                              chainBudgetSeconds: 0.4)
        let started = ContinuousClock.now
        let result = try await triage(router)
        let elapsed = started.duration(to: .now)
        #expect(result.isDeterministic)
        #expect(elapsed < .seconds(5))
    }

    @Test func theSameChainWithinTheCapAnswers() async throws {
        let quick = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageReply)], delay: .milliseconds(50))
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: quick)], chainBudgetSeconds: 3)
        let result = try await triage(router)
        #expect(!result.isDeterministic)
        #expect(result.firstMove == "Open the invoice folder and find September.")
    }

    @Test func aStalledRetriageKeepsThePreviousResult() async throws {
        let previous = TriageResult(project: nil, priority: 3, due: nil, depth: .deep, estimateMinutes: 45,
                                    energyKind: .creative, firstMove: "Open the draft.", labels: [],
                                    rationale: "Needs quiet.")
        let slow = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageReply)], delay: .seconds(30))
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: slow)], chainBudgetSeconds: 0.4)
        let started = ContinuousClock.now
        let result = try await router.retriage(title: "Send the invoice", notes: "", previous: previous,
                                               feedback: "too long", projectNames: [], labelNames: [], today: 20_000)
        #expect(result == previous)
        #expect(started.duration(to: .now) < .seconds(5))
    }
}

/// With AI off, asking again (key R, Retry, an automatic run) sends nothing.
struct AIOffMakesNoCallTests {

    @Test func aRouterInOffModeNeverTouchesItsClient() async throws {
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageReply)])
        let router = AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: client)])
        let result = try await router.triage(title: "Send the invoice", notes: "", projectNames: [], labelNames: [],
                                             today: 20_000, lockedFields: [], context: .empty)
        #expect(result.isDeterministic)
        #expect(await client.callCount == 0)
    }

    @Test func positiveControlTheSameRouterInAllowAnyModeDoesCall() async throws {
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageReply)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        _ = try await router.triage(title: "Send the invoice", notes: "", projectNames: [], labelNames: [],
                                    today: 20_000, lockedFields: [], context: .empty)
        #expect(await client.callCount == 1)
    }

    @Test func askPolicyTable() {
        let table: [(switchOn: Bool, router: Bool, mode: AIMode?, expected: Bool)] = [
            (true, true, .allowAny, true),
            (true, true, .privateOnly, true),
            (true, true, nil, true),
            (false, true, .allowAny, false),
            (true, false, nil, false),
            (true, true, .off, false),
            (false, false, nil, false),
        ]
        for row in table {
            #expect(AICallPolicy.mayAsk(switchOn: row.switchOn, hasRouter: row.router, mode: row.mode) == row.expected,
                    "switch=\(row.switchOn) router=\(row.router) mode=\(String(describing: row.mode))")
        }
    }
}

/// What leaves the Mac as a list of task titles is capped.
struct EgressCapTests {

    @Test func captureSendsAtMostFiftyOpenTitles() async throws {
        let titles = (0..<200).map { "Existing open task \($0)" }
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content("")])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        _ = await router.extractTasks(from: "- Call Alex\n- Pay the invoice", projectNames: [],
                                      existingOpenTitles: titles, today: 20_000)
        let log = await client.callLog
        #expect(log.count == 1)
        let user = log[0].messages.first { $0.role == "user" }?.content ?? ""
        let sent = try NSRegularExpression(pattern: "Existing open task [0-9]+").numberOfMatches(in: user, range: NSRange(user.startIndex..., in: user))
        #expect(sent == 50)
        #expect(user.contains("Existing open task 49"))
        #expect(!user.contains("Existing open task 50"))
    }

    @Test func aLongTitleIsCutAndAnEmailInATitleIsRemoved() {
        let long = String(repeating: "x", count: 200)
        let capped = EgressLimits.cappedTitles([long, "Mail anna@example.com about it"])
        #expect(capped[0].count == 80)
        #expect(capped[1] == "Mail [redacted-email] about it")
        #expect(EgressLimits.cappedTitles([]).isEmpty)
        #expect(EgressLimits.cappedTitles(["a", "b", "c"], limit: 2) == ["a", "b"])
    }

    @Test func theTriageExamplesRedactTitles() {
        let context = TriageContext(examples: [
            TriageExample(title: "Write to anna@example.com", projectName: nil, priority: .none, effort: .none,
                          depth: .unknown, hadDeadline: false, open: true, recency: 1)
        ])
        let line = context.promptLines.first ?? ""
        #expect(line.contains("[redacted-email]"))
        #expect(!line.contains("anna@example.com"))
    }

    @Test func theEgressSentenceAndTheRuleStringsExistInBothLanguages() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("Kronos/Resources/Localizable.xcstrings"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        func value(_ key: String, _ lang: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let loc = (entry?["localizations"] as? [String: Any])?[lang] as? [String: Any]
            return (loc?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        let keys = [
            "settings.ai.egress", "settings.coach.section.houserules", "settings.coach.houserules.help",
            "settings.coach.houserules.empty", "settings.coach.houserules.meta",
            "settings.coach.houserules.origin.agent", "settings.coach.houserules.origin.you",
            "settings.coach.houserules.origin.correction", "settings.coach.houserules.scope.all",
            "settings.coach.houserules.scope.triage", "settings.coach.houserules.scope.impuls",
            "settings.coach.houserules.scope.ordo", "settings.coach.houserules.toggle.a11y",
            "settings.coach.houserules.delete", "settings.coach.houserules.delete.confirm",
            "settings.coach.houserules.delete.a11y",
        ]
        for key in keys {
            let en = value(key, "en") ?? ""
            let hr = value(key, "hr") ?? ""
            #expect(!en.isEmpty, "\(key) en")
            #expect(!hr.isEmpty, "\(key) hr")
        }
        let egress = value("settings.ai.egress", "en") ?? ""
        for word in ["title", "300 characters", "8 titles", "project and label names", "house rules",
                     "6,000 characters", "50 open task titles", "removed first", "nothing is sent"] {
            #expect(egress.contains(word), "egress sentence misses \(word)")
        }
        // The renamed vocabulary: none of the old feature names in a value.
        for key in keys {
            for lang in ["en", "hr"] {
                let text = value(key, lang) ?? ""
                for banned in ["Impuls", "Ordo", "Triage", "Trijaža", "Razvrstavanje"] {
                    #expect(!text.contains(banned), "\(key) \(lang) uses \(banned)")
                }
            }
        }
    }
}
