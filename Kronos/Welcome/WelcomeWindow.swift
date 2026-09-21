// Kronos/Welcome/WelcomeWindow.swift
// First-run tour: seven pages, one feature each, in the same window chrome as Permissions
// (Kronos/Permissions/PermissionsWindow.swift). No images — each page's illustration is the
// feature's own key caps, so the window stays small and localises for free. Shown once, then
// reachable from Help > "Welcome to Kronos…" and built from the same WelcomePages list a
// screenshot reads, so the tour and its snapshots can never drift apart.
import SwiftUI
import AppKit
import KronosCore

@Observable
@MainActor
final class WelcomeModel {
    private(set) var index = 0
    let pages = WelcomePages.all

    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == pages.count - 1 }
    var page: WelcomePage { pages[index] }

    func next() { if !isLast { index += 1 } }
    func back() { if !isFirst { index -= 1 } }
}

struct WelcomeWindow: View {
    let model: WelcomeModel
    var onFinish: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            KHairline()
            footer
        }
        .frame(width: 560, height: 520)
        .background(Tok.bg)
        .onKeyPress(.leftArrow) { model.back(); return .handled }
        .onKeyPress(.rightArrow) { advance(); return .handled }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text(String(format: String(localized: "welcome.eyebrow"), model.page.id, model.pages.count))
                .font(Typo.sectionHdr)
                .foregroundStyle(Tok.textTertiary)

            Text(String(localized: String.LocalizationValue(model.page.titleKey)))
                .font(Typo.title)
                .foregroundStyle(Tok.textPrimary)

            Text(String(localized: String.LocalizationValue(model.page.bodyKey)))
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let beforeKey = model.page.exampleBeforeKey, let afterKey = model.page.exampleAfterKey {
                HStack(spacing: Space.x1) {
                    Text(String(localized: String.LocalizationValue(beforeKey)))
                        .font(Typo.mono)
                    KKeyHint("!", "!", "!")
                    Text(String(localized: String.LocalizationValue(afterKey)))
                        .font(Typo.mono)
                }
                .foregroundStyle(Tok.textPrimary)
                .padding(.horizontal, Space.x3)
                .padding(.vertical, Space.x2)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Tok.controlFill))
            }

            if !model.page.hints.isEmpty {
                KKeyHintRow(model.page.hints.map(resolvedHint))
            }

            if model.page.id == WelcomePages.all.count {
                Button(String(localized: "welcome.page7.github")) {
                    guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil,
                          let url = URL(string: "https://github.com/marketingbybesic/kronos") else { return }
                    NSWorkspace.shared.open(url)
                }
                .kButton(.secondary)
            }

            Spacer()
        }
        .padding(Space.x6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The page id keys the transition so SwiftUI treats each page as a fresh subtree
        // (an in-place text swap reads as a jump-cut edit, not a page turn).
        .id(model.page.id)
    }

    /// Turns one page's hint source into the caps + label `KKeyHintRow` draws. A hotkey id
    /// with no matching registry entry (should never happen; the self-test asserts every id
    /// referenced by WelcomePages exists) renders no caps rather than crashing a first-run
    /// window — an empty label reads as a blank hint, not a launch failure.
    private func resolvedHint(_ hint: WelcomeHint) -> (keys: [String], label: String) {
        let label = hint.labelKey.isEmpty ? "" : String(localized: String.LocalizationValue(hint.labelKey))
        switch hint.source {
        case .literal(let keys):
            return (keys, label)
        case .hotkey(let id):
            let keys = HotkeyRegistry.current(for: id)?.displayKeys ?? []
            return (keys, label)
        }
    }

    private var footer: some View {
        HStack(spacing: Space.x4) {
            Button(String(localized: "common.skip")) { onFinish() }
                .kButton(.ghost)

            Spacer()

            HStack(spacing: Space.x1) {
                ForEach(model.pages) { page in
                    Circle()
                        .fill(page.id == model.page.id ? Tok.textPrimary : Tok.textDisabled)
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            Button(model.isLast ? String(localized: "welcome.start") : String(localized: "common.next")) {
                advance()
            }
            .kButton(.primary)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Space.x4)
    }

    private func advance() {
        if model.isLast { onFinish() } else { model.next() }
    }
}

/// Single-instance NSWindow host, same pattern as `PermissionsWindowController`.
@MainActor
enum WelcomeWindowController {
    private static var window: NSWindow?

    static func show(model: WelcomeModel? = nil, onFinish: @escaping () -> Void = {}) {
        let model = model ?? WelcomeModel()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = WelcomeWindow(model: model, onFinish: { window?.close(); onFinish() })
        let hosting = NSHostingController(rootView: view)
        let panel = NSWindow(contentViewController: hosting)
        panel.title = String(localized: "welcome.title")
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in window = nil }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
