// Kronos/Hotkeys/HotkeyRecorderField.swift
// A recorder for registry entries that are NOT a `KeyboardShortcuts.Name` (every rebindable
// entry except `global.quickadd`, `global.meetingcapture`, `global.showordo` — all three now
// have real KeyboardShortcuts.Names and get the package's own Recorder, see
// SettingsShortcutsTab.swift). Window-scope bindings already apply live via
// `HotkeyViewModifiers.swift`'s `.hotkey(id)` (it re-reads `HotkeyRegistry.current` every time
// KronosApp's commands body re-evaluates), so the only missing piece was a way to WRITE an
// override; this view is that piece. List-scope entries stay text-only — the registry itself
// marks them `isRebindable: false`.
//
// This view fixes four defects a first version had:
// 1. No visible affordance — a rebindable row looked identical to a fixed one at rest. Now a
//    bordered pill (Tok.controlFill + border, matching KeyboardShortcuts.Recorder's own look)
//    with an inside-label "x" reset button once overridden, and the recording state shown in
//    the accent colour.
// 2. `handle(_:)` accepted a bare unmodified letter, so recording "a" made every future "a"
//    keystroke anywhere fire a menu command. `HotkeyRecordAcceptance.evaluate` now gates every
//    recorded combination (needs a real modifier, rejects macOS-reserved combos) before
//    `onRecorded` is ever called; a rejection keeps recording and shows a calm inline hint.
// 3. The monitor had no window guard and no single-recorder rule. `HotkeyRecordingCoordinator`
//    (below) is the one shared "who is recording" state — starting a new recording cancels
//    whichever row was previously active. The monitor only acts on events whose `event.window`
//    is this row's own hosting window, and recording also ends on a mouse click anywhere else,
//    on `.onDisappear`, and when the window resigns key (not just Esc).
// Same NSEvent local-monitor pattern as `Kronos/Palette/CommandPaletteView.swift`'s KeyCatcher.
import AppKit
import SwiftUI

/// The one row (if any) currently capturing keystrokes, app-wide. A second row starting to
/// record must cancel the first — two live monitors racing the same keystroke would both try
/// to claim it.
@MainActor
final class HotkeyRecordingCoordinator {
    static let shared = HotkeyRecordingCoordinator()
    private(set) var activeID: String?
    private var onCancelled: (() -> Void)?

    func begin(_ id: String, onCancelled: @escaping () -> Void) {
        if let previous = activeID, previous != id { self.onCancelled?() }
        activeID = id
        self.onCancelled = onCancelled
    }

    func end(_ id: String) {
        guard activeID == id else { return }
        activeID = nil
        onCancelled = nil
    }
}

struct HotkeyRecorderField: View {
    /// Stable identity for the single-recorder rule — the registry id for a `HotkeyRegistry`
    /// row, or any other stable string for a caller with its own store (kept generic so this
    /// view does not need to know which store it is writing to).
    let id: String
    let binding: HotkeyBinding
    let isOverridden: Bool
    var allowsBareKey = false
    let onRecorded: (HotkeyBinding) -> Void
    let onResetToDefault: () -> Void
    @State private var isRecording = false
    @State private var rejectionHintKey: String?
    @Environment(\.kAccent) private var accent

    var body: some View {
        HStack(spacing: Space.x1) {
            Button {
                startRecording()
            } label: {
                Group {
                    if isRecording {
                        Text(rejectionHintKey.map { String(localized: String.LocalizationValue($0)) }
                             ?? String(localized: "settings.shortcuts.recording"))
                            .font(Typo.meta)
                            .foregroundStyle(rejectionHintKey != nil ? Tok.textTertiary : accent)
                    } else {
                        keyCaps(binding.displayKeys)
                    }
                }
                .frame(minWidth: Metrics.minHit * 2, minHeight: Metrics.minHit)
                .padding(.horizontal, Space.x2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOverridden, !isRecording {
                Button {
                    onResetToDefault()
                } label: {
                    Icon("x", size: Metrics.iconXS)
                        .foregroundStyle(Tok.textTertiary)
                        .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "settings.shortcuts.resetrow"))
            }
        }
        .padding(.horizontal, Space.x1)
        // Same bordered-pill shape as KeyboardShortcuts.Recorder's own AppKit control, so a
        // rebindable row reads as a CONTROL at rest, not as inert text.
        .background(Tok.controlFill, in: RoundedRectangle(cornerRadius: Radius.control))
        .kBorder(isRecording ? accent : Tok.borderControl, radius: Radius.control)
        .background(RecorderMonitor(onKey: handle, onWindowResignedKey: cancelRecording))
        .onDisappear { HotkeyRecordingCoordinator.shared.end(id) }
    }

    private func startRecording() {
        rejectionHintKey = nil
        isRecording = true
        HotkeyRecordingCoordinator.shared.begin(id) { isRecording = false; rejectionHintKey = nil }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        rejectionHintKey = nil
        HotkeyRecordingCoordinator.shared.end(id)
    }

    /// `true` while this row is both recording AND the active claim — a stale monitor from a
    /// row that lost the claim (another row started recording) must not react to keystrokes
    /// meant for the new one.
    private var isActiveRecorder: Bool { isRecording && HotkeyRecordingCoordinator.shared.activeID == id }

    private func handle(_ event: NSEvent) -> Bool {
        guard isActiveRecorder else { return false }
        if event.type == .leftMouseDown || event.type == .rightMouseDown { cancelRecording(); return false }
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 { cancelRecording(); return true } // Esc cancels
        if event.keyCode == 51 || event.keyCode == 117 {          // Delete/Backspace: restore default
            cancelRecording()
            onResetToDefault()
            return true
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), let scalar = chars.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) || chars == "\\" else { return true }
        let flags = event.modifierFlags
        let recorded = HotkeyBinding(chars, shift: flags.contains(.shift), option: flags.contains(.option),
                                      control: flags.contains(.control), command: flags.contains(.command))
        switch HotkeyRecordAcceptance.evaluate(recorded, allowsBareKey: allowsBareKey) {
        case .rejected(let reasonKey):
            rejectionHintKey = reasonKey
            return true // stay in recording, show the hint
        case .accepted:
            HotkeyRecordingCoordinator.shared.end(id)
            isRecording = false
            rejectionHintKey = nil
            onRecorded(recorded)
            return true
        }
    }

    @ViewBuilder
    private func keyCaps(_ keys: [String]) -> some View {
        switch keys.count {
        case 0: EmptyView()
        case 1: KKeyHint(keys[0])
        case 2: KKeyHint(keys[0], keys[1])
        case 3: KKeyHint(keys[0], keys[1], keys[2])
        default: KKeyHint(keys[0], keys[1], keys[2], keys[3])
        }
    }
}

/// Invisible NSView that owns the local key/mouse-down monitor for the lifetime it's on
/// screen, and observes its own window resigning key. Only forwards events whose `event.window`
/// is this row's own hosting window — a local monitor already only sees this app's events, but
/// a Settings window can share the process with e.g. a Quick Add panel, and an event meant for
/// a different Kronos window must not be swallowed here.
private struct RecorderMonitor: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    let onWindowResignedKey: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.window = view.window
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
                guard event.window == nil || event.window === context.coordinator.window else { return event }
                return onKey(event) ? nil : event
            }
            if let window = view.window {
                context.coordinator.resignObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: .main
                ) { _ in Task { @MainActor in onWindowResignedKey() } }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        weak var window: NSWindow?
        var resignObserver: NSObjectProtocol?
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }
}
