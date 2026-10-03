import Testing
import Foundation
@testable import KronosCore

@Suite struct WebhookDeliveryTests {

    // MARK: signature (vectors computed outside the code under test with openssl)

    @Test func signatureEqualsTheHandComputedHMACVector() {
        let body = Data(#"{"seq":7}"#.utf8)
        #expect(WebhookSigner.header(secret: "whsec_test", timestamp: 1_700_000_000, body: body)
                == "t=1700000000,v1=4654277b939f77fdfa991be3ca7c7a7e60a6f55cd6f4deaf902fee03c9fb5ef5")
    }

    @Test func aDifferentSecretGivesADifferentSignaturePositiveControl() {
        let body = Data(#"{"seq":7}"#.utf8)
        let other = WebhookSigner.header(secret: "other", timestamp: 1_700_000_000, body: body)
        #expect(other == "t=1700000000,v1=59e9e41bf6e921dce7ef40d79023b6973f9e1d26b250d756e476678acb977f6f")
        #expect(other != WebhookSigner.header(secret: "whsec_test", timestamp: 1_700_000_000, body: body))
    }

    @Test func aDifferentTimestampOrBodyChangesTheSignature() {
        let a = WebhookSigner.header(secret: "s", timestamp: 1, body: Data("x".utf8))
        #expect(a != WebhookSigner.header(secret: "s", timestamp: 2, body: Data("x".utf8)))
        #expect(a != WebhookSigner.header(secret: "s", timestamp: 1, body: Data("y".utf8)))
    }

    // MARK: retry schedule

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func retryScheduleIsOneFiveThirtyMinutesThenTwoHours() {
        // attempts so far -> wait before the next try
        let table: [(attempts: Int, wait: TimeInterval)] = [(1, 60), (2, 300), (3, 1800), (4, 7200), (5, 7200), (9, 7200)]
        for row in table {
            let last = t0.addingTimeInterval(100)
            #expect(WebhookRetry.decide(eventAt: t0, attempts: row.attempts, lastAttempt: last, now: last.addingTimeInterval(row.wait - 1))
                    == .wait(until: last.addingTimeInterval(row.wait)), "attempts \(row.attempts)")
            #expect(WebhookRetry.decide(eventAt: t0, attempts: row.attempts, lastAttempt: last, now: last.addingTimeInterval(row.wait))
                    == .deliverNow, "attempts \(row.attempts)")
        }
    }

    @Test func aFreshEventIsDeliveredAtOnce() {
        #expect(WebhookRetry.decide(eventAt: t0, attempts: 0, lastAttempt: nil, now: t0) == .deliverNow)
    }

    @Test func anEventIsDeadAfterTwentyFourHours() {
        #expect(WebhookRetry.decide(eventAt: t0, attempts: 3, lastAttempt: t0, now: t0.addingTimeInterval(86_399)) != .dead)
        #expect(WebhookRetry.decide(eventAt: t0, attempts: 3, lastAttempt: t0, now: t0.addingTimeInterval(86_400)) == .dead)
        #expect(WebhookRetry.decide(eventAt: t0, attempts: 0, lastAttempt: nil, now: t0.addingTimeInterval(90_000)) == .dead)
    }

    // MARK: targets

    @Test func targetsParseFromTheStoredString() {
        #expect(DeliveryTarget.parse("https://relay.example.com/ingest") == .webhook(URL(string: "https://relay.example.com/ingest")!))
        #expect(DeliveryTarget.parse("ntfy+https://ntfy.example.com/kronos-agents") == .ntfy(URL(string: "https://ntfy.example.com/kronos-agents")!))
        #expect(DeliveryTarget.parse(#"exec:["ssh","relay","/opt/relay/bin/ingest-kronos"]"#) == .command(["ssh", "relay", "/opt/relay/bin/ingest-kronos"]))
        #expect(DeliveryTarget.parse("http://127.0.0.1:9000/hook") == .webhook(URL(string: "http://127.0.0.1:9000/hook")!))
    }

    @Test func targetsThatAreNotSafeAreRefused() {
        for bad in ["http://example.com/hook", "ftp://example.com/x", "file:///etc/passwd", "https://", "", "  ", "exec:[]",
                    "exec:not json", #"exec:[""]"#, "ntfy+http://example.com/t", "javascript:alert(1)"] {
            #expect(DeliveryTarget.parse(bad) == nil, "\(bad) must not parse")
        }
    }

    @Test func aCommandTargetIsAnArgvAndNeverAShellString() {
        // A shell string would be one element; the parser accepts only a JSON array and keeps every element as is.
        let t = DeliveryTarget.parse(#"exec:["echo","a; rm -rf /","$(whoami)"]"#)
        #expect(t == .command(["echo", "a; rm -rf /", "$(whoami)"]))
        #expect(DeliveryTarget.parse("exec:echo hello") == nil)
    }

    @Test func theStoredFormRoundTrips() {
        for raw in ["https://a.example/x", "ntfy+https://ntfy.example/topic", #"exec:["ssh","h","c"]"#] {
            #expect(DeliveryTarget.parse(raw)?.stored == raw)
        }
    }

    @Test func ntfyIsOffUntilATargetIsSetAndHasItsOwnTopic() throws {
        // No target string = no delivery; the preset topic is part of the person's URL, never the person's own alert topic.
        #expect(DeliveryTarget.parse(nil) == nil)
        let t = try #require(DeliveryTarget.parse("ntfy+https://ntfy.example.com/kronos-agents"))
        if case .ntfy(let u) = t { #expect(u.lastPathComponent == "kronos-agents" && u.lastPathComponent != "me-agenti") } else { Issue.record("not ntfy") }
    }
}
