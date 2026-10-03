// Kronos/Welcome/OnboardingIntro.swift — the ONLY first-run screen. It replaced a
// 7-page reading tour that ADHD users skipped. One screen: what Kronos is, how it is meant to
// be used (four ideas, one line each), and where to learn the rest: the "Learn Kronos" card at
// the top of the list, tried whenever the user has time. One button. Closing it counts the same.
// Help > "Welcome to Kronos…" shows it again.
import SwiftUI
import AppKit

struct OnboardingIntroView: View {
    var onStart: () -> Void = {}
    var onLater: () -> Void = {}
    @Environment(\.kAccent) private var accent
    /// How many blocks have appeared (icon, title, ideas 1-4, footer): staggered on appear so the
    /// screen reads top to bottom instead of landing as one wall of text. Reduce Motion: all at once.
    @State private var revealed = 0

    /// What Kronos is and how it is meant to be used: four ideas, one line each.
    private static let ideas: [(icon: String, titleKey: String, bodyKey: String)] = [
        ("plus", "welcome.intro.idea1.title", "welcome.intro.idea1.body"),
        ("zap", "welcome.intro.idea2.title", "welcome.intro.idea2.body"),
        ("check", "welcome.intro.idea3.title", "welcome.intro.idea3.body"),
        ("map", "welcome.intro.idea4.title", "welcome.intro.idea4.body"),
    ]

    private static var quickAddKeys: [String] {
        HotkeyRegistry.current(for: "global.quickadd")?.displayKeys ?? []
    }

    /// "Version 1.2 (34)" from the app bundle, nothing when there is no bundle (tools, snapshots).
    private static var versionText: String? {
        let info = Bundle.main.infoDictionary
        guard let label = OnboardingLogic.versionLabel(short: info?["CFBundleShortVersionString"] as? String,
                                                       build: info?["CFBundleVersion"] as? String) else { return nil }
        return String(format: String(localized: "welcome.intro.version"), label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.x5) {
                appIcon
                    .opacity(revealed > 0 ? 1 : 0)
                    .offset(y: revealed > 0 ? 0 : 6)
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text(String(localized: "welcome.intro.title"))
                        .font(Typo.display)
                        .foregroundStyle(Tok.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(localized: "welcome.intro.body"))
                        .font(Typo.lead)
                        .foregroundStyle(Tok.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(revealed > 1 ? 1 : 0)
                .offset(y: revealed > 1 ? 0 : 6)
                VStack(alignment: .leading, spacing: Space.x4) {
                    ForEach(Array(Self.ideas.enumerated()), id: \.element.titleKey) { i, idea in
                        HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                            Icon(idea.icon, size: Metrics.iconM).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: Space.x1) {
                                Text(String(localized: String.LocalizationValue(idea.titleKey)))
                                    .font(Typo.heading)
                                    .foregroundStyle(Tok.textPrimary)
                                Text(String(localized: String.LocalizationValue(idea.bodyKey)))
                                    .font(Typo.body)
                                    .foregroundStyle(Tok.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                // The first idea names "the quick add shortcut": show the keys, read
                                // from the registry so a remapped shortcut shows correctly.
                                if i == 0, !Self.quickAddKeys.isEmpty {
                                    KKeyHintItem(Self.quickAddKeys, label: String(localized: "welcome.intro.idea1.keys"))
                                }
                            }
                        }
                        .opacity(revealed > i + 2 ? 1 : 0)
                        .offset(y: revealed > i + 2 ? 0 : 6)
                    }
                }
                Spacer(minLength: 0)
            }
            .onAppear {
                guard !Motion.reduceMotion, ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil else { revealed = 7; return }
                for step in 1...7 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(step)) {
                        withAnimation(Motion.curve(Motion.done)) { revealed = step }
                    }
                }
            }
            .padding(Space.x6)
            .frame(maxWidth: .infinity, alignment: .leading)
            KHairline()
            HStack(spacing: Space.x4) {
                Button(String(localized: "welcome.intro.later")) { onLater() }
                    .kButton(.ghost)
                Spacer()
                if let version = Self.versionText {
                    Text(version)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    Spacer()
                }
                Button(String(localized: "welcome.intro.start")) { onStart() }
                    .kButton(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Space.x4)
        }
        .frame(width: 600, height: 640)
        .background(Tok.bg)
    }

    /// The real icon (hexagon + rings) with a soft accent halo; a quiet plate under the snapshot
    /// harness, where no bundle icon exists.
    @ViewBuilder
    private var appIcon: some View {
        ZStack {
            Circle().fill(accent.opacity(0.18)).frame(width: 72, height: 72).blur(radius: 14)
            if ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil, let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 56, height: 56)
            } else {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Tok.controlFill).frame(width: 56, height: 56)
                    .overlay(Icon("zap", size: Metrics.iconL).foregroundStyle(accent))
            }
        }
        .frame(width: 72, height: 72)
    }
}

/// Single-instance NSWindow host.
@MainActor
enum OnboardingIntroController {
    private static var window: NSWindow?
    /// Closing the window with its red button counts as "Later": the tour still starts.
    private static var decided = false
    private static var laterAction: (() -> Void)?

    /// Help > "Welcome to Kronos…": the intro screen, whose "Show me around" starts the checklist and the tour.
    static func showFromHelp() {
        guard let model = AppDelegate.shared?.model else { return }
        show(onStart: {
                OnboardingCenter.shared.start(model: model)
                TourCenter.shared.start(model: model)
            },
            onLater: {})
    }

    static func show(onStart: @escaping () -> Void, onLater: @escaping () -> Void) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        decided = false
        laterAction = onLater
        let view = OnboardingIntroView(onStart: { decided = true; window?.close(); onStart() },
                                       onLater: { decided = true; window?.close(); onLater() })
        let panel = NSWindow(contentViewController: NSHostingController(rootView: view))
        panel.title = String(localized: "welcome.title")
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.center()
        window = panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in
                window = nil
                if !decided { decided = true; laterAction?() }
                laterAction = nil
            }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
