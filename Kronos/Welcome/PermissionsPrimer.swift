// Kronos/Welcome/PermissionsPrimer.swift — the one screen between "you finished the basics" and
// the Permissions window. It says, before anything is asked, that every permission is optional
// and what asking means. Its button is "Continue", never "Allow": a button that sounds like the
// system's own prompt makes people believe they already answered it (Apple's privacy guidance
// for the screen before a permission request). Continue opens the Permissions window; "Not now"
// or closing it leaves everything as it was.
import SwiftUI
import AppKit
import KronosCore

struct PermissionsPrimerView: View {
    var onContinue: () -> Void = {}
    var onLater: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.x3) {
                Text(String(localized: "welcome.primer.title"))
                    .font(Typo.title)
                    .foregroundStyle(Tok.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(localized: "welcome.primer.body"))
                    .font(Typo.body)
                    .foregroundStyle(Tok.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Space.x6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            KHairline()
            HStack(spacing: Space.x4) {
                Button(String(localized: "welcome.primer.later")) { onLater() }
                    .kButton(.ghost)
                    .keyboardShortcut(.cancelAction)
                    .uiTestAnchor("primer.later")
                Spacer()
                Button(String(localized: "welcome.primer.continue")) { onContinue() }
                    .kButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .uiTestAnchor("primer.continue")
            }
            .padding(Space.x4)
        }
        .frame(width: 460, height: 280)
        .background(Tok.bg)
    }
}

/// A plain window does not map Escape to its cancel button by itself: Esc closes it, like "Not now".
private final class PrimerWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

/// Single-instance host, same pattern as `OnboardingIntroController`.
@MainActor
enum PermissionsPrimerController {
    private static var window: NSWindow?

    /// Hermetic runs (snapshot, live test) never open it on their own: only `force` does.
    static func show(force: Bool = false, onContinue: @escaping () -> Void) {
        guard force || !KronosEnv.isHermetic else { return }
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = PermissionsPrimerView(onContinue: { window?.close(); onContinue() },
                                         onLater: { window?.close() })
        let panel = PrimerWindow(contentViewController: NSHostingController(rootView: view))
        panel.title = String(localized: "permissions.title")
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.center()
        window = panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in window = nil }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The open primer window, for the live test.
    static var isOpen: Bool { window != nil }
    static func close() { window?.close() }
}
