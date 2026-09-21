// Kronos/Hotkeys/OptionChordMonitor.swift
// Opt-Cmd-T (Triage) was observed to never fire. A live UI test's own mandatory positive
// control (Shift-Cmd-N, a chord that DOES work) also failed to deliver through
// `NSApp.postEvent`/`performKeyEquivalent` in every run — proof the synthetic harness cannot
// judge a real keypress, not proof the binding is dead. SwiftUI's `.keyboardShortcut(_:modifiers:)`
// with `localization: .automatic` (the default `.hotkey(_:)` uses) is the remaining unproven
// suspect for Option chords specifically. This is a SECOND, independent path to the same
// action: a local key monitor that matches Option-modified window-scope chords by PHYSICAL
// KEY CODE (never by `characters`, which Option changes) and fires the existing menu item
// directly. It changes nothing for any chord without Option, since those are already known to
// work through the normal path.
// The pure decision (OptionChordDecider/OptionChordDecision/KeyWindowKind/OptionChordOutcome)
// lives in OptionChordDecider.swift so a self-test can compile it standalone.
import AppKit
import KronosCore

/// The live monitor: wires `OptionChordDecider` to a real `NSEvent.addLocalMonitorForEvents`,
/// finds the matching `NSMenuItem`, fires it via `performActionForItem` (the same path already
/// proved to open Triage by click), and appends one outcome line to a capped log file.
@MainActor
enum OptionChordMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    /// Returns true if this event was consumed (menu action fired or explicitly stood down for
    /// a reason worth silencing further propagation is NOT what stand-down means here — a
    /// stand-down or a miss both return the event untouched; only `.fire` consumes it).
    private static func handle(_ event: NSEvent) -> Bool {
        let bindings = HotkeyRegistry.entries
            .filter { $0.scope == .window }
            .compactMap { entry -> (id: String, binding: HotkeyBinding)? in
                guard let b = HotkeyRegistry.current(for: entry.id) else { return nil }
                return (entry.id, b)
            }
        let isRecording = HotkeyRecordingCoordinator.shared.activeID != nil
        let kind: KeyWindowKind = (NSApp.keyWindow.map { !( $0 is NSPanel) && $0.title == "Kronos" } ?? false) ? .kronosMain : .other

        switch OptionChordDecider.decide(keyCode: event.keyCode, modifierFlags: event.modifierFlags,
                                           bindings: bindings, isRecording: isRecording, keyWindowKind: kind) {
        case .pass:
            return false
        case .standDown(let reason):
            log(id: "-", outcome: reason == "recording" ? .stoodDownRecording : .stoodDownWrongWindow)
            return false
        case .fire(let registryID):
            guard let binding = HotkeyRegistry.current(for: registryID),
                  let item = findMenuItem(matching: binding) else {
                log(id: registryID, outcome: .itemMissing)
                return false
            }
            guard item.isEnabled, let menu = item.menu else {
                log(id: registryID, outcome: .itemDisabled)
                return false
            }
            menu.performActionForItem(at: menu.index(of: item))
            log(id: registryID, outcome: .fired)
            return true
        }
    }

    private static func findMenuItem(matching binding: HotkeyBinding) -> NSMenuItem? {
        guard let ch = binding.key.first else { return nil }
        var want: NSEvent.ModifierFlags = []
        if binding.shift { want.insert(.shift) }
        if binding.option { want.insert(.option) }
        if binding.control { want.insert(.control) }
        if binding.command { want.insert(.command) }
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.keyEquivalent.lowercased() == String(ch).lowercased(),
                   item.keyEquivalentModifierMask == want { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    // MARK: Diagnostic log (types/ids only, never typed text, never a task title)

    private static func log(id: String, outcome: OptionChordOutcome) {
        let url = KronosStore.containerDirectory().appendingPathComponent("hotkey.log")
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) id=\(id) outcome=\(outcome.rawValue)\n"
        var lines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        lines.append(line.trimmingCharacters(in: .newlines))
        if lines.count > 200 { lines = Array(lines.suffix(200)) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
