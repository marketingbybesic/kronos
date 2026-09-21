// Kronos/App/WindowWidthReader.swift — a GeometryReader-fed `windowWidth` was measured to
// durably disagree with the real NSWindow after the note-link picker `.sheet` closes, and the
// app's actual on-screen layout follows the wrong number (sidebar+list fill the window with the
// inspector pane fully gone, not a squeezed third pane). AppKit is the ONE source of truth now,
// never cross-checked against GeometryReader (two sources that can disagree is how bugs like
// this happen in the first place).
//
// A zero-size NSViewRepresentable reports `self.window` from `viewDidMoveToWindow` — THIS
// view's own window, not `NSApp.keyWindow` (wrong the moment Settings or the quick add panel is
// key instead of the main window) — and AppShellView observes width-relevant notifications
// scoped to that one window object.
import AppKit
import SwiftUI

struct WindowWidthReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override var intrinsicContentSize: NSSize { .zero }
        override func viewDidMoveToWindow() { onWindow?(window) }
    }
}

/// Owns the notification subscriptions and hands `AppShellView` a fresh
/// `window.contentView.bounds.width` on every event that could change it — never
/// `GeometryReader`, never `NSApp.keyWindow` (see file header). `contentView.bounds.width`, not
/// `contentLayoutRect.width`: the two only differ by the titlebar's height inset on this
/// (non-full-size-content) window, never by width, and `bounds` is available unconditionally.
/// A class, not a struct, so `@State` holds the SAME instance across `AppShellView`'s body
/// re-evaluations and its observers are registered exactly once per real window.
@Observable
final class WindowWidthObserver {
    private(set) var width: CGFloat?
    private weak var window: NSWindow?
    private var tokens: [NSObjectProtocol] = []

    /// Called once `WindowWidthReader` reports the real window (and again if it ever changes,
    /// though a shell view is only ever hosted in one window for its lifetime in practice).
    func attach(to newWindow: NSWindow?) {
        guard newWindow !== window else { return }
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        window = newWindow
        guard let newWindow else { return }
        width = newWindow.contentView?.bounds.width
        for name: Notification.Name in [
            NSWindow.didResizeNotification,
            NSWindow.didEndSheetNotification,
            NSWindow.didBecomeMainNotification,
        ] {
            let token = NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                self?.width = newWindow.contentView?.bounds.width
            }
            tokens.append(token)
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
