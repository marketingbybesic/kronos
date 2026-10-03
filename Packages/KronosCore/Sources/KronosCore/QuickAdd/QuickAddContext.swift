import Foundation

// Context-aware quick add: when ⌃⌥K opens over another app, read what that app is showing once
// and offer it as a starting title plus removable link chips:
//   - selected text (Accessibility) becomes the title;
//   - the front browser tab gives its title and a web chip;
//   - the selected Mail message gives its subject and a mail chip (the message link is slow to
//     get from Mail, so it is time-boxed and the subject alone is the fallback);
//   - the Finder selection gives file chips; the selected Apple Note gives a note chip.
//
// Everything that talks to the system (Apple Events, osascript, Accessibility) sits behind
// `QuickAddContextEnvironment`, so this file is pure orchestration and text handling: the app
// passes the live environment, tests and the live UI test pass a scripted one. Nothing here
// ever asks for a permission on its own: an app whose Automation answer is not known yet comes
// back as `consent`, and the panel asks only when the person clicks that chip.

/// Which reader applies to the app the panel was opened over.
public enum QuickAddContextSource: Equatable, Sendable {
    case safari
    /// Chrome and the browsers that share its scripting dictionary (Arc, Brave, Edge, Vivaldi).
    case chromium
    case mail
    case finder
    case notes
    /// Any other app: only its selected text is read.
    case other

    static let table: [String: QuickAddContextSource] = [
        "com.apple.Safari": .safari, "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium, "com.google.Chrome.beta": .chromium, "com.google.Chrome.canary": .chromium,
        "company.thebrowser.Browser": .chromium, "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium, "com.vivaldi.Vivaldi": .chromium,
        "com.apple.mail": .mail,
        "com.apple.finder": .finder,
        "com.apple.Notes": .notes,
    ]

    public static func source(bundleID: String?) -> QuickAddContextSource {
        bundleID.flatMap { table[$0] } ?? .other
    }

    /// True for the sources read through Apple Events (they need the Automation answer).
    public var isScripted: Bool { self != .other }
}

/// The Automation answer for one target app, read without prompting.
public enum QuickAddAutomation: Equatable, Sendable { case granted, notAsked, denied }

/// What reading the front app produced.
public struct QuickAddContext: Equatable, Sendable {
    /// A starting title (selected text, a page title, a mail subject), or nil.
    public var prefill: String?
    /// Chips: a web page, a mail message, an Apple Note. Never one with an empty reference.
    public var links: [ContextLink]
    /// Finder selection, as POSIX paths; the app turns them into file links (bookmarks).
    public var filePaths: [String]
    /// Set when the app's Automation answer is not known yet: the panel offers a chip that asks.
    public var consent: QuickAddContextSource?

    public init(prefill: String? = nil, links: [ContextLink] = [], filePaths: [String] = [],
                consent: QuickAddContextSource? = nil) {
        self.prefill = prefill
        self.links = links
        self.filePaths = filePaths
        self.consent = consent
    }

    public static let empty = QuickAddContext()
    public var isEmpty: Bool { prefill == nil && links.isEmpty && filePaths.isEmpty && consent == nil }
}

/// The system side of reading context. The live implementation is in the app
/// (Kronos/QuickAdd/QuickAddContextLive.swift).
public protocol QuickAddContextEnvironment: Sendable {
    /// The Automation answer for `bundleID`; `ask` true may show the system prompt.
    func automation(_ bundleID: String, ask: Bool) async -> QuickAddAutomation
    /// Runs an AppleScript and returns its text output, or nil on error or after `timeout` seconds.
    func runScript(_ source: String, timeout: TimeInterval) async -> String?
    /// The selected text of the focused element of the app with `pid`, or nil.
    func selectedText(pid: Int32) async -> String?
}

public enum QuickAddContextReader {
    /// Seconds Mail gets to hand over the selected message's id before the subject alone is used.
    public static let mailLinkTimeout: TimeInterval = 1
    /// Seconds any other single script gets.
    public static let scriptTimeout: TimeInterval = 1.5
    /// Longest starting title taken from selected text.
    public static let maxPrefill = 200
    /// Most files taken from a Finder selection.
    public static let maxFiles = 5

    /// Reads the app the panel was opened over. `ask` true only after the person clicked the
    /// consent chip.
    public static func read(bundleID: String?, pid: Int32, environment env: QuickAddContextEnvironment,
                            ask: Bool = false) async -> QuickAddContext {
        let source = QuickAddContextSource.source(bundleID: bundleID)
        let selection = prefill(fromSelection: await env.selectedText(pid: pid))
        guard source.isScripted, let bundleID else { return QuickAddContext(prefill: selection) }

        switch await env.automation(bundleID, ask: ask) {
        case .denied:
            return QuickAddContext(prefill: selection)
        case .notAsked:
            return QuickAddContext(prefill: selection, consent: source)
        case .granted:
            break
        }

        switch source {
        case .safari, .chromium:
            guard let out = await env.runScript(Scripts.browserTab(bundleID: bundleID, source: source), timeout: scriptTimeout),
                  let tab = parseBrowserTab(out) else { return QuickAddContext(prefill: selection) }
            return QuickAddContext(prefill: selection ?? prefill(fromSelection: tab.title),
                                   links: [ContextLink(kind: .web, reference: tab.url, displayName: tab.title.isEmpty ? tab.url : tab.title)])
        case .mail:
            let subject = await env.runScript(Scripts.mailSubject, timeout: scriptTimeout).flatMap(clean)
            guard subject != nil || selection != nil else { return .empty }
            let id = await env.runScript(Scripts.mailMessageID, timeout: mailLinkTimeout).flatMap(clean)
            return mailContext(subject: subject, messageID: id, selection: selection)
        case .finder:
            let paths = await env.runScript(Scripts.finderSelection, timeout: scriptTimeout).map(parseFinderSelection) ?? []
            return QuickAddContext(prefill: selection, filePaths: paths)
        case .notes:
            guard let out = await env.runScript(Scripts.notesSelection, timeout: scriptTimeout),
                  let note = parseNote(out) else { return QuickAddContext(prefill: selection) }
            return QuickAddContext(prefill: selection,
                                   links: [ContextLink(kind: .appleNote, reference: note.id, displayName: note.title)])
        case .other:
            return QuickAddContext(prefill: selection)
        }
    }

    // MARK: Pure pieces

    /// Selected text as a starting title: one line, single spaces, at most `maxPrefill`
    /// characters cut at a word. Nil when nothing readable is left.
    public static func prefill(fromSelection raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        var out = ""
        for w in words {
            let next = out.isEmpty ? String(w) : out + " " + w
            if next.count > maxPrefill { break }
            out = next
        }
        if out.isEmpty, let first = words.first { out = String(first.prefix(maxPrefill)) }
        return out.isEmpty ? nil : out
    }

    /// Mail's subject is the title; the message id, when Mail gave it in time, is the chip.
    /// Selected text in the message beats the subject as the title.
    public static func mailContext(subject: String?, messageID: String?, selection: String?) -> QuickAddContext {
        var links: [ContextLink] = []
        if let messageID, let url = mailURL(messageID: messageID) {
            links.append(ContextLink(kind: .email, reference: url, displayName: subject ?? messageID))
        }
        return QuickAddContext(prefill: selection ?? subject.flatMap(prefill(fromSelection:)), links: links)
    }

    /// `message://%3C<id>%3E`, the link Mail itself opens. Angle brackets around the id are optional.
    public static func mailURL(messageID raw: String) -> String? {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        guard !id.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "<>/?#%")
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "message://%3C" + encoded + "%3E"
    }

    /// "<title>\t<url>" -> the tab; nil unless the url is http(s).
    public static func parseBrowserTab(_ out: String) -> (title: String, url: String)? {
        let parts = out.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard parts.count >= 2 else { return nil }
        let url = parts.last!.trimmingCharacters(in: .whitespaces)
        let title = parts.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: url), u.scheme == "http" || u.scheme == "https", u.host != nil else { return nil }
        return (title, url)
    }

    /// One POSIX path per line; blank lines dropped, at most `maxFiles`.
    public static func parseFinderSelection(_ out: String) -> [String] {
        Array(out.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
            .prefix(maxFiles))
    }

    /// "<id>\t<title>" -> the note; nil without an id.
    public static func parseNote(_ out: String) -> (id: String, title: String)? {
        let parts = out.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard let id = parts.first?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        let title = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (id, title.isEmpty ? id : title)
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: Scripts (fixed text; only a bundle id from `QuickAddContextSource.table` goes in)

    public enum Scripts {
        static func browserTab(bundleID: String, source: QuickAddContextSource) -> String {
            // Safari calls the front tab "current tab" and its title "name"; Chromium browsers
            // say "active tab" and "title".
            let tab = source == .safari ? "current tab" : "active tab"
            let title = source == .safari ? "name" : "title"
            return """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set t to \(tab) of front window
                return (\(title) of t) & (character id 9) & (URL of t)
            end tell
            """
        }

        static let mailSubject = """
        tell application id "com.apple.mail"
            set s to selection
            if s is {} then return ""
            return subject of item 1 of s
        end tell
        """

        static let mailMessageID = """
        tell application id "com.apple.mail"
            set s to selection
            if s is {} then return ""
            return message id of item 1 of s
        end tell
        """

        static let finderSelection = """
        tell application id "com.apple.finder"
            set out to ""
            repeat with i in (get selection)
                set out to out & POSIX path of (i as alias) & linefeed
            end repeat
            return out
        end tell
        """

        static let notesSelection = """
        tell application id "com.apple.Notes"
            set s to selection
            if s is {} then return ""
            set n to item 1 of s
            return (id of n) & (character id 9) & (name of n)
        end tell
        """
    }
}
