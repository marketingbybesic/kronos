import Testing
import Foundation
@testable import KronosCore

/// A scripted system: canned Automation answers, canned script outputs (matched by a word the
/// script contains), optional delays, and a log of what was asked. It honours each call's
/// timeout like the live runner (which kills osascript), so a hang shows up as nil in time.
final class ScriptedContextEnvironment: QuickAddContextEnvironment, @unchecked Sendable {
    var answers: [String: QuickAddAutomation] = [:]
    var asked: [String] = []
    var outputs: [(match: String, output: String?, delay: TimeInterval)] = []
    var selection: String?
    var timeouts: [String: TimeInterval] = [:]
    private let lock = NSLock()

    func automation(_ bundleID: String, ask: Bool) async -> QuickAddAutomation {
        lock.withLock { if ask { asked.append(bundleID) } }
        let answer = answers[bundleID] ?? .denied
        if ask, answer == .notAsked { return .granted }
        return answer
    }

    func runScript(_ source: String, timeout: TimeInterval) async -> String? {
        guard let hit = outputs.first(where: { source.contains($0.match) }) else { return nil }
        lock.withLock { timeouts[hit.match] = timeout }
        if hit.delay > timeout {
            try? await Task.sleep(for: .seconds(timeout))
            return nil
        }
        if hit.delay > 0 { try? await Task.sleep(for: .seconds(hit.delay)) }
        return hit.output
    }

    func selectedText(pid: Int32) async -> String? { selection }
}

struct QuickAddContextTests {
    typealias R = QuickAddContextReader

    @Test func sourceTable() {
        let rows: [(String?, QuickAddContextSource)] = [
            ("com.apple.Safari", .safari), ("com.google.Chrome", .chromium), ("company.thebrowser.Browser", .chromium),
            ("com.brave.Browser", .chromium), ("com.microsoft.edgemac", .chromium), ("com.apple.mail", .mail),
            ("com.apple.finder", .finder), ("com.apple.Notes", .notes), ("com.apple.TextEdit", .other),
            ("com.example.unknown", .other), (nil, .other),
        ]
        for (id, source) in rows { #expect(QuickAddContextSource.source(bundleID: id) == source, "\(id ?? "nil")") }
    }

    @Test func prefillFromSelection() {
        #expect(R.prefill(fromSelection: nil) == nil)
        #expect(R.prefill(fromSelection: "  \n\t ") == nil)
        #expect(R.prefill(fromSelection: "Send the\n  offer to  Ana\n") == "Send the offer to Ana")
        let long = String(repeating: "word ", count: 60)          // 300 characters
        let cut = R.prefill(fromSelection: long)!
        #expect(cut.count == 199)                                  // 40 words of 4 + 39 spaces
        #expect(!cut.hasSuffix(" "))
        let oneHugeWord = String(repeating: "x", count: 300)
        #expect(R.prefill(fromSelection: oneHugeWord)?.count == 200)
    }

    @Test func parsers() {
        #expect(R.parseBrowserTab("Quarterly report – Docs\thttps://example.com/q3\n")! == ("Quarterly report – Docs", "https://example.com/q3"))
        #expect(R.parseBrowserTab("Tab\twith\ttabs\thttps://example.com")! == ("Tab with tabs", "https://example.com"))
        #expect(R.parseBrowserTab("Settings\tchrome://settings") == nil)
        #expect(R.parseBrowserTab("") == nil)
        #expect(R.parseFinderSelection("/home/a/x.pdf\n\n/home/a/folder/\nnot a path\n") == ["/home/a/x.pdf", "/home/a/folder/"])
        #expect(R.parseFinderSelection((1...9).map { "/f\($0)" }.joined(separator: "\n")).count == 5)
        #expect(R.parseNote("x-coredata://ABC/ICNote/p12\tShopping list")! == ("x-coredata://ABC/ICNote/p12", "Shopping list"))
        #expect(R.parseNote("x-coredata://ABC/ICNote/p12\t")! == ("x-coredata://ABC/ICNote/p12", "x-coredata://ABC/ICNote/p12"))
        #expect(R.parseNote("\tNo id") == nil)
    }

    @Test func mailURL() {
        #expect(R.mailURL(messageID: "<CAB12@mail.example.com>") == "message://%3CCAB12@mail.example.com%3E")
        #expect(R.mailURL(messageID: "abc.def@example.org") == "message://%3Cabc.def@example.org%3E")
        #expect(R.mailURL(messageID: "a/b?c@x") == "message://%3Ca%2Fb%3Fc@x%3E")
        #expect(R.mailURL(messageID: " <> ") == nil)
    }

    @Test func mailContext() {
        let full = R.mailContext(subject: "Invoice 2291", messageID: "<id@x>", selection: nil)
        #expect(full.prefill == "Invoice 2291")
        #expect(full.links == [ContextLink(kind: .email, reference: "message://%3Cid@x%3E", displayName: "Invoice 2291")])
        let slow = R.mailContext(subject: "Invoice 2291", messageID: nil, selection: nil)
        #expect(slow.prefill == "Invoice 2291")
        #expect(slow.links.isEmpty)
        let selected = R.mailContext(subject: "Invoice 2291", messageID: "<id@x>", selection: "pay by Friday")
        #expect(selected.prefill == "pay by Friday")
    }

    @Test func safariTabGivesTitleAndWebChip() async {
        let env = ScriptedContextEnvironment()
        env.answers["com.apple.Safari"] = .granted
        env.outputs = [("current tab", "Quarterly report\thttps://example.com/q3", 0)]
        let c = await R.read(bundleID: "com.apple.Safari", pid: 1, environment: env)
        #expect(c.prefill == "Quarterly report")
        #expect(c.links == [ContextLink(kind: .web, reference: "https://example.com/q3", displayName: "Quarterly report")])
        #expect(c.consent == nil)
    }

    @Test func chromeUsesActiveTabAndSelectionWins() async {
        let env = ScriptedContextEnvironment()
        env.answers["com.google.Chrome"] = .granted
        env.outputs = [("active tab", "Docs\thttps://example.com/d", 0)]
        env.selection = "Fix the footer"
        let c = await R.read(bundleID: "com.google.Chrome", pid: 1, environment: env)
        #expect(c.prefill == "Fix the footer")
        #expect(c.links.map(\.reference) == ["https://example.com/d"])
    }

    /// Mail hands over the subject but not the message id within 1 s: the subject alone.
    @Test func mailWithNoAnswerFallsBackToTheSubject() async {
        let env = ScriptedContextEnvironment()
        env.answers["com.apple.mail"] = .granted
        env.outputs = [("subject of", "Invoice 2291", 0), ("message id of", "<id@x>", 5)]
        let start = Date()
        let c = await R.read(bundleID: "com.apple.mail", pid: 1, environment: env)
        let elapsed = Date().timeIntervalSince(start)
        #expect(c.prefill == "Invoice 2291")
        #expect(c.links.isEmpty)
        #expect(env.timeouts["message id of"] == 1)
        #expect(elapsed < 1.8, "took \(elapsed) s")
    }

    @Test func mailInTimeGivesAMailChip() async {
        let env = ScriptedContextEnvironment()
        env.answers["com.apple.mail"] = .granted
        env.outputs = [("subject of", "Invoice 2291", 0), ("message id of", "<id@x>", 0.1)]
        let c = await R.read(bundleID: "com.apple.mail", pid: 1, environment: env)
        #expect(c.links.map(\.kind) == [.email])
    }

    @Test func finderAndNotes() async {
        let env = ScriptedContextEnvironment()
        env.answers = ["com.apple.finder": .granted, "com.apple.Notes": .granted]
        env.outputs = [("POSIX path", "/home/a/brief.pdf\n", 0), ("com.apple.Notes", "x-coredata://N/p1\tGroceries", 0)]
        let f = await R.read(bundleID: "com.apple.finder", pid: 1, environment: env)
        #expect(f.filePaths == ["/home/a/brief.pdf"])
        #expect(f.prefill == nil)
        let n = await R.read(bundleID: "com.apple.Notes", pid: 1, environment: env)
        #expect(n.links == [ContextLink(kind: .appleNote, reference: "x-coredata://N/p1", displayName: "Groceries")])
    }

    /// Never asks on its own: an unknown answer comes back as a consent chip and no script runs;
    /// asking (the chip's click) reads.
    @Test func consentOnlyWhenAsked() async {
        let env = ScriptedContextEnvironment()
        env.answers["com.apple.Safari"] = .notAsked
        env.outputs = [("current tab", "Q\thttps://example.com/q", 0)]
        let first = await R.read(bundleID: "com.apple.Safari", pid: 1, environment: env)
        #expect(first.consent == .safari)
        #expect(first.links.isEmpty)
        #expect(env.asked.isEmpty)
        #expect(env.timeouts.isEmpty)
        let second = await R.read(bundleID: "com.apple.Safari", pid: 1, environment: env, ask: true)
        #expect(env.asked == ["com.apple.Safari"])
        #expect(second.links.map(\.reference) == ["https://example.com/q"])
    }

    @Test func deniedAndOtherAppsReadOnlyTheSelection() async {
        let env = ScriptedContextEnvironment()
        env.answers["com.apple.mail"] = .denied
        env.selection = "Ring the bank"
        env.outputs = [("subject of", "S", 0)]
        let mail = await R.read(bundleID: "com.apple.mail", pid: 1, environment: env)
        #expect(mail == QuickAddContext(prefill: "Ring the bank"))
        let other = await R.read(bundleID: "com.apple.TextEdit", pid: 1, environment: env)
        #expect(other == QuickAddContext(prefill: "Ring the bank"))
        #expect(env.timeouts.isEmpty)
    }

    /// A tab that is not a web page (settings, a blank tab) gives no chip, never an empty link.
    @Test func nonWebTabGivesNothing() async {
        let env = ScriptedContextEnvironment()
        env.answers["com.apple.Safari"] = .granted
        env.outputs = [("current tab", "Favorites\tfavorites://", 0)]
        let c = await R.read(bundleID: "com.apple.Safari", pid: 1, environment: env)
        #expect(c.isEmpty)
    }
}
