// Kronos/Welcome/WelcomePages.swift
// The welcome tour's page data: one struct per page, read by both WelcomeWindow and
// WelcomeSnapshots so a screenshot and the real window always show the same content. Hint
// keys are hotkey ids, resolved against HotkeyRegistry at render time (never a literal cap)
// so a user's remapped key shows correctly, and a plain string for the few pills that are
// not keyboard shortcuts at all (Impuls' energy levels).
import Foundation

struct WelcomeHint {
    enum Source {
        /// Resolved via `HotkeyRegistry.current(for: id)?.displayKeys`.
        case hotkey(id: String)
        /// A fixed cap that names no shortcut (Triage's field legend, Impuls' energy pills).
        case literal([String])
    }
    let source: Source
    let labelKey: String
}

struct WelcomePage: Identifiable {
    let id: Int
    let titleKey: String
    let bodyKey: String
    let hints: [WelcomeHint]
    /// A short mono example line, only on the page that teaches quick-add syntax. Split
    /// around the priority marker so "!!!" is never baked into a localized string — the
    /// catalog strips "!" everywhere (build-strings.mjs's `clean()`, the app-wide "no !"
    /// rule) — and instead renders as a real `KKeyHint` cap, same as the quick-add legend
    /// itself (`quickadd.legend.priority`).
    let exampleBeforeKey: String?
    let exampleAfterKey: String?

    init(id: Int, titleKey: String, bodyKey: String, hints: [WelcomeHint],
         exampleBeforeKey: String? = nil, exampleAfterKey: String? = nil) {
        self.id = id
        self.titleKey = titleKey
        self.bodyKey = bodyKey
        self.hints = hints
        self.exampleBeforeKey = exampleBeforeKey
        self.exampleAfterKey = exampleAfterKey
    }
}

enum WelcomePages {
    static let all: [WelcomePage] = [
        WelcomePage(
            id: 1, titleKey: "welcome.page1.title", bodyKey: "welcome.page1.body",
            hints: [
                WelcomeHint(source: .hotkey(id: "global.quickadd"), labelKey: "welcome.page1.hint.anywhere"),
                WelcomeHint(source: .hotkey(id: "window.newtask"), labelKey: "welcome.page1.hint.here"),
            ],
            exampleBeforeKey: "welcome.page1.example.before", exampleAfterKey: "welcome.page1.example.after"),
        WelcomePage(
            id: 2, titleKey: "welcome.page2.title", bodyKey: "welcome.page2.body",
            hints: [
                WelcomeHint(source: .hotkey(id: "window.triage"), labelKey: "welcome.page2.hint.open"),
                WelcomeHint(source: .literal(["1", "–", "4"]), labelKey: "welcome.page2.hint.priority"),
                WelcomeHint(source: .literal(["S", "M", "L"]), labelKey: "welcome.page2.hint.effort"),
                WelcomeHint(source: .literal(["T", "W", "N"]), labelKey: "welcome.page2.hint.deadline"),
                WelcomeHint(source: .literal(["⏎"]), labelKey: "welcome.page2.hint.accept"),
            ]),
        WelcomePage(
            id: 3, titleKey: "welcome.page3.title", bodyKey: "welcome.page3.body",
            hints: [
                WelcomeHint(source: .hotkey(id: "window.impuls"), labelKey: "welcome.page3.hint.open"),
                WelcomeHint(source: .literal(["Low"]), labelKey: ""),
                WelcomeHint(source: .literal(["Mid"]), labelKey: ""),
                WelcomeHint(source: .literal(["High"]), labelKey: ""),
            ]),
        WelcomePage(
            id: 4, titleKey: "welcome.page4.title", bodyKey: "welcome.page4.body",
            hints: [
                WelcomeHint(source: .hotkey(id: "window.capture"), labelKey: "welcome.page4.hint.here"),
                WelcomeHint(source: .hotkey(id: "global.meetingcapture"), labelKey: "welcome.page4.hint.anywhere"),
            ]),
        WelcomePage(
            id: 5, titleKey: "welcome.page5.title", bodyKey: "welcome.page5.body",
            hints: [
                WelcomeHint(source: .hotkey(id: "global.showordo"), labelKey: "welcome.page5.hint.show"),
                WelcomeHint(source: .hotkey(id: "window.timeblocks"), labelKey: "welcome.page5.hint.blocks"),
            ]),
        WelcomePage(
            id: 6, titleKey: "welcome.page6.title", bodyKey: "welcome.page6.body",
            hints: [
                WelcomeHint(source: .hotkey(id: "window.palette"), labelKey: "welcome.page6.hint.palette"),
            ]),
        WelcomePage(
            id: 7, titleKey: "welcome.page7.title", bodyKey: "welcome.page7.body",
            hints: []),
    ]

    /// Every hotkey id a page references, for the self-test to check against
    /// `HotkeyRegistry.entries` so a renamed or removed id is caught at build time, not by a
    /// blank cap in a screenshot nobody looked at.
    static var referencedHotkeyIDs: [String] {
        all.flatMap { $0.hints.compactMap { hint in
            if case .hotkey(let id) = hint.source { return id }
            return nil
        } }
    }
}
