import Testing
import Foundation
@testable import KronosCore

/// A lock-guarded flag, since `availability` closures are `@Sendable` and a
/// plain captured `var` cannot be mutated from one under Swift 6 checking.
final class CheckFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func mark() { lock.withLock { called = true } }
    var wasCalled: Bool { lock.withLock { called } }
}

/// `AppleIntelligenceClient` and the `AIMode.privateOnly`/`.off` gates around
/// it. Every test injects `availability`, so none of these need the real
/// framework enabled or even present at runtime — only at compile time,
/// behind `#if canImport(FoundationModels)`.
struct AppleIntelligenceClientTests {

    // MARK: - Required gate test: appleClientSkippedWhenUnavailable

    @Test func appleClientSkippedWhenUnavailable() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let apple = AppleIntelligenceClient(availability: { .notEnabled })
            let deterministicOnly = FixtureAIClient(modelID: "sonnet-unreachable", script: [.failure(.http(500))])
            let router = AIRouter(mode: .allowAny, candidates: [
                AIRoutedCandidate(client: deterministicOnly),
                AIRoutedCandidate(client: apple)
            ])
            let result = try await router.triage(title: "Send the invoice", notes: "", projectNames: [],
                                                 labelNames: [], today: Day.today(), lockedFields: [])
            // Apple was unavailable, the other candidate failed too: the
            // router must still land on the deterministic path rather than
            // hanging or throwing — it never actually calls the FoundationModels
            // API when `availability` reports anything but `.available`.
            #expect(result.isDeterministic)
            return
        }
        #endif
        // This build cannot import FoundationModels at all (or the OS is
        // below 26): the factory must still return nil rather than crash.
        await MainActor.run {
            #expect(AppleIntelligenceClientFactory.make() == nil)
        }
    }

    @Test func appleClientNeverCallsTheModelWhenUnavailable() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let checkedAvailability = CheckFlag()
            let apple = AppleIntelligenceClient(availability: {
                checkedAvailability.mark()
                return .notEligible
            })
            let request = AIRequest(model: apple.modelID, messages: [.system("s"), .user("u")], kind: .triage)
            await #expect(throws: AIError.self) {
                try await apple.send(request)
            }
            #expect(checkedAvailability.wasCalled)
        }
        #endif
    }

    @Test func appleIntelligenceStatusLineIsCalmNeverAlarming() {
        for case let availability in [
            AppleIntelligenceAvailability.available, .notEnabled, .notEligible, .modelNotReady, .osTooOld
        ] {
            let line = availability.statusLine
            #expect(!line.contains("!"))
            #expect(!line.isEmpty)
        }
    }

    // MARK: - Required gate test: privateOnlyAcceptsOnDevice

    @Test func privateOnlyAcceptsOnDevice() async throws {
        let onDevice = FixtureAIClient(modelID: "apple-on-device", dataPolicy: .onDevice,
                                       script: [.content(triageJSON())])
        let router = AIRouter(mode: .privateOnly, candidates: [AIRoutedCandidate(client: onDevice)])
        let result = try await router.triage(title: "Send the September invoice to Alex", notes: "",
                                             projectNames: [], labelNames: [], today: Day.today(), lockedFields: [])
        #expect(!result.isDeterministic)
        #expect(await onDevice.callCount == 1)
    }

    @Test func privateOnlyAlsoAcceptsZeroRetention() async throws {
        let zeroRetention = FixtureAIClient(modelID: "zero-retention-model", dataPolicy: .zeroRetention,
                                            script: [.content(triageJSON())])
        let router = AIRouter(mode: .privateOnly, candidates: [AIRoutedCandidate(client: zeroRetention)])
        let result = try await router.triage(title: "Send the September invoice to Alex", notes: "",
                                             projectNames: [], labelNames: [], today: Day.today(), lockedFields: [])
        #expect(!result.isDeterministic)
    }

    @Test func privateOnlyExcludesMayTrainAndUnknownPolicies() async throws {
        let mayTrain = FixtureAIClient(modelID: "cloud-model", dataPolicy: .mayTrain,
                                       script: [.content(triageJSON())])
        let router = AIRouter(mode: .privateOnly, candidates: [AIRoutedCandidate(client: mayTrain)])
        let result = try await router.triage(title: "Send the September invoice to Alex", notes: "",
                                             projectNames: [], labelNames: [], today: Day.today(), lockedFields: [])
        // Filtered out entirely: falls straight to deterministic, and the
        // excluded client is never even called.
        #expect(result.isDeterministic)
        #expect(await mayTrain.callCount == 0)
    }

    // MARK: - Required gate test: aiModeOffStillNeverTouchesAnyClient

    @Test func aiModeOffStillNeverTouchesAnyClient() async throws {
        let onDevice = FixtureAIClient(modelID: "apple-on-device", dataPolicy: .onDevice,
                                       script: [.content(triageJSON())])
        let cloud = FixtureAIClient(modelID: "cloud-model", dataPolicy: .mayTrain,
                                    script: [.content(triageJSON())])
        let router = AIRouter(mode: .off, candidates: [
            AIRoutedCandidate(client: onDevice), AIRoutedCandidate(client: cloud)
        ])
        let result = try await router.triage(title: "Send the invoice", notes: "", projectNames: [],
                                             labelNames: [], today: Day.today(), lockedFields: [])
        #expect(result.isDeterministic)
        #expect(await onDevice.callCount == 0)
        #expect(await cloud.callCount == 0)
    }

    private func triageJSON() -> String {
        """
        {"project":null,"priority":2,"due":null,"depth":"shallow","estimateMinutes":15,
         "energyKind":"admin","firstMove":"Open the invoice folder and find September.",
         "labels":[],"rationale":"One document and one email, no preparation needed."}
        """
    }
}
