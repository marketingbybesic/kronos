// `--mcp-background`: the bridge (kronos-mcp) opens the app with `open -g ... --args
// --mcp-background` so an AI client can reach the MCP server without a window jumping up.
// The window is hidden right after launch and comes back on any Dock click / activation.
// If MCP is switched off there is nothing to serve, so quit instead of idling invisibly.
import AppKit
import KronosCore

@MainActor
final class MCPBackgroundLaunch {
    static let flag = "--mcp-background"
    static var requested: Bool { CommandLine.arguments.contains(flag) }

    private var hidden: [NSWindow] = []
    private var activeObserver: NSObjectProtocol?

    func begin() {
        guard Self.requested else { return }
        guard MCPSettingsKeys.isEnabled else {
            FileHandle.standardError.write(Data("Kronos: --mcp-background but MCP is disabled in settings; quitting\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
            return
        }
        hideMainWindow(attempt: 0)
    }

    /// SwiftUI creates the main window after launch finishes, so retry for ~3 s.
    private func hideMainWindow(attempt: Int) {
        let wins = NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) && $0.isVisible }
        if !wins.isEmpty {
            hidden = wins
            wins.forEach { $0.orderOut(nil) }
            // Armed only now, so the launch-time activation cannot undo the hide.
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { _ = self?.restore() } }
            return
        }
        guard attempt < 30 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.hideMainWindow(attempt: attempt + 1)
        }
    }

    /// Shows the hidden window again; true when there was one to show.
    @discardableResult
    func restore() -> Bool {
        guard !hidden.isEmpty else { return false }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        let wins = hidden
        hidden = []
        wins.first?.makeKeyAndOrderFront(nil)
        wins.dropFirst().forEach { $0.orderFront(nil) }
        return true
    }
}
