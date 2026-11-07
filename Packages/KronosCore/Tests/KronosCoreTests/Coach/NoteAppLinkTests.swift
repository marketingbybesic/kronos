import Testing
import Foundation
@testable import KronosCore

/// Hand-written tables for obsidian/notion reference recognition and normalization — every
/// expected value is a literal, never derived from the code under test.
struct NoteAppLinkTests {
    @Test func obsidianReferenceRecognition() {
        let cases: [(String, Bool)] = [
            ("obsidian://open?vault=Work&file=Plan", true),
            ("OBSIDIAN://open?vault=Work", true),               // scheme is case-insensitive
            ("obsidian://", true),
            ("https://notion.so/Plan", false),
            ("/home/me/Vault/Plan.md", false),                // a path is not a reference by itself
            ("not a url at all", false),
            ("", false),
        ]
        for (input, expected) in cases {
            #expect(NoteAppLink.isObsidianReference(input) == expected, "input=\(input)")
        }
    }

    @Test func notionReferenceRecognition() {
        let cases: [(String, Bool)] = [
            ("https://notion.so/My-Page-abc123", true),
            ("https://www.notion.so/My-Page-abc123", true),
            ("http://notion.so/My-Page", true),
            ("HTTPS://NOTION.SO/Page", true),                    // scheme/host case-insensitive
            ("notion://open?id=abc123", true),
            ("https://example.com/notion.so", false),            // host must BE notion.so, not contain it
            ("https://evilnotion.so/Page", false),                // no dot boundary before "notion.so"
            ("obsidian://open?vault=Work", false),
            ("not a url at all", false),
            ("", false),
        ]
        for (input, expected) in cases {
            #expect(NoteAppLink.isNotionReference(input) == expected, "input=\(input)")
        }
    }

    @Test func normalizeObsidian() {
        #expect(NoteAppLink.normalize("obsidian://open?vault=Work&file=Plan", app: .obsidian)
                == "obsidian://open?vault=Work&file=Plan")
        #expect(NoteAppLink.normalize("  obsidian://open?vault=Work  ", app: .obsidian)
                == "obsidian://open?vault=Work")                 // trimmed
        #expect(NoteAppLink.normalize("/home/me/Vault/Plan.md", app: .obsidian)
                == URL(fileURLWithPath: "/home/me/Vault/Plan.md").absoluteString)
        #expect(NoteAppLink.normalize("Vault/Plan.md", app: .obsidian) == nil)       // relative path
        #expect(NoteAppLink.normalize("/", app: .obsidian) == nil)                   // no file name
        #expect(NoteAppLink.normalize("", app: .obsidian) == nil)
        #expect(NoteAppLink.normalize("https://notion.so/Plan", app: .obsidian) == nil)
    }

    @Test func normalizeNotion() {
        #expect(NoteAppLink.normalize("https://notion.so/My-Page-abc123", app: .notion)
                == "https://notion.so/My-Page-abc123")
        #expect(NoteAppLink.normalize("  https://www.notion.so/Page  ", app: .notion)
                == "https://www.notion.so/Page")                  // trimmed
        #expect(NoteAppLink.normalize("notion://open?id=abc", app: .notion) == "notion://open?id=abc")
        #expect(NoteAppLink.normalize("/home/me/Vault/Plan.md", app: .notion) == nil)
        #expect(NoteAppLink.normalize("not a link", app: .notion) == nil)
        #expect(NoteAppLink.normalize("", app: .notion) == nil)
    }

    @Test func normalizeAppleNotesAlwaysNil() {
        #expect(NoteAppLink.normalize("obsidian://open?vault=Work", app: .appleNotes) == nil)
        #expect(NoteAppLink.normalize("https://notion.so/Page", app: .appleNotes) == nil)
    }

    @Test func findReturnsOnlyTheMatchingAppsLink() {
        let obsidian = ContextLink(kind: .web, reference: "obsidian://open?vault=Work", displayName: "Obsidian note")
        let notion = ContextLink(kind: .web, reference: "https://notion.so/Page", displayName: "Notion page")
        let plainWeb = ContextLink(kind: .web, reference: "https://example.com", displayName: "example.com")
        let notes = [obsidian, notion, plainWeb].reduce("") { $1.appending(to: $0) }

        #expect(NoteAppLink.find(in: notes, app: .obsidian) == obsidian)
        #expect(NoteAppLink.find(in: notes, app: .notion) == notion)
        #expect(NoteAppLink.find(in: notes, app: .appleNotes) == nil)
    }

    @Test func replacingSwapsOnlyTheTrackedLinkAndKeepsOthers() {
        let oldObsidian = ContextLink(kind: .web, reference: "obsidian://open?vault=Work&file=Old", displayName: "Old")
        let plainWeb = ContextLink(kind: .web, reference: "https://example.com", displayName: "example.com")
        let notes = [oldObsidian, plainWeb].reduce("") { $1.appending(to: $0) }

        let newObsidian = ContextLink(kind: .web, reference: "obsidian://open?vault=Work&file=New", displayName: "New")
        let replaced = NoteAppLink.replacing(with: newObsidian, app: .obsidian, in: notes)

        let links = ContextLink.findAll(in: replaced)
        #expect(links.count == 2)
        #expect(links.contains(newObsidian))
        #expect(!links.contains(oldObsidian))
        #expect(links.contains(plainWeb))
    }

    @Test func replacingWithNoExistingLinkJustAppends() {
        let plainWeb = ContextLink(kind: .web, reference: "https://example.com", displayName: "example.com")
        let notes = plainWeb.appending(to: "")
        let notion = ContextLink(kind: .web, reference: "https://notion.so/Page", displayName: "Page")
        let replaced = NoteAppLink.replacing(with: notion, app: .notion, in: notes)
        let links = ContextLink.findAll(in: replaced)
        #expect(links.count == 2)
        #expect(links.contains(notion))
        #expect(links.contains(plainWeb))
    }

    @Test func preferenceDefaultsToAppleNotesAndRoundTrips() {
        let suite = "kronos.test.noteapp." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(NoteAppPreference.current(defaults: defaults) == .appleNotes)
        NoteAppPreference.set(.obsidian, defaults: defaults)
        #expect(NoteAppPreference.current(defaults: defaults) == .obsidian)
        NoteAppPreference.set(.notion, defaults: defaults)
        #expect(NoteAppPreference.current(defaults: defaults) == .notion)
    }

    // Positive control: a deliberately wrong expectation must fail. Kept commented out —
    // uncommenting it is the "break" proof this suite is not vacuous.
    // @Test func brokenControl() { #expect(NoteAppLink.isObsidianReference("https://notion.so") == true) }
}
