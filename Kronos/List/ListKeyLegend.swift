// Kronos/List/ListKeyLegend.swift
// Hold ⌥ while the list has the keyboard and a legend of the list's single keys appears over it;
// let go (or press any key) and it is gone. Every cap and name comes from HotkeyRegistry, so a
// rebound key shows its new letter, and the HR layout shows what the HR keyboard prints.
// The ⌥ hold is read by a local flags monitor: the legend shows only after a short hold, so a
// quick ⌥ chord (⌥⌘F) never flashes it.
import SwiftUI
import AppKit
import KronosCore

/// One legend line: the caps, the name, the registry ids it stands for.
struct ListLegendLine: Identifiable {
    let id: String
    let keys: [String]
    let label: String
}

@MainActor
enum ListLegendContent {
    /// Legend lines in grammar order. Digits and S/M/L are one cap per key (never "1-4").
    static func lines() -> [ListLegendLine] {
        func caps(_ id: String) -> [String] {
            (HotkeyRegistry.current(for: id) ?? HotkeyRegistry.entries.first { $0.id == id }?.defaultBinding)?.displayKeys ?? []
        }
        func title(_ id: String) -> String {
            guard let key = HotkeyRegistry.entries.first(where: { $0.id == id })?.titleKey else { return "" }
            return String(localized: String.LocalizationValue(key))
        }
        func line(_ id: String) -> ListLegendLine { ListLegendLine(id: id, keys: caps(id), label: title(id)) }
        let priority = ["list.priority.none", "list.priority.low", "list.priority.medium", "list.priority.high", "list.priority.urgent"]
        let effort = ["list.effort.small", "list.effort.medium", "list.effort.large"]
        return [
            line("list.toggle"),
            line("list.plan.today"),
            line("list.plan.tomorrow"),
            line("list.snooze"),
            line("list.due"),
            line("list.project"),
            ListLegendLine(id: "priority", keys: priority.flatMap(caps), label: String(localized: "list.legend.priority")),
            ListLegendLine(id: "effort", keys: effort.flatMap(caps), label: String(localized: "list.legend.effort")),
            line("list.breakdown"),
            line("list.waiting"),
            line("list.someday"),
            line("list.focuspin"),
            line("list.expandall"),
            line("list.open"),
            ListLegendLine(id: "extend", keys: caps("list.extend.up") + caps("list.extend.down").suffix(1),
                           label: String(localized: "list.legend.extend")),
            line("list.delete"),
        ]
    }
}

/// The legend card.
struct ListKeyLegend: View {
    var body: some View {
        let lines = ListLegendContent.lines()
        let half = (lines.count + 1) / 2
        KPanel(padding: Space.x4, radius: Radius.card, floating: true) {
            VStack(alignment: .leading, spacing: Space.x3) {
                Text(String(localized: "list.legend.title"))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                HStack(alignment: .top, spacing: Space.x6) {
                    column(Array(lines.prefix(half)))
                    column(Array(lines.dropFirst(half)))
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "list.legend.title"))
        .accessibilityValue(lines.map { $0.keys.joined(separator: " ") + " " + $0.label }.joined(separator: ", "))
        .uiTestAnchor("list.legend")
    }

    private func column(_ lines: [ListLegendLine]) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            ForEach(lines) { KKeyHintItem($0.keys, label: $0.label) }
        }
    }
}

/// Watches ⌥ for the list: true while ⌥ alone has been held a moment and `isActive` holds.
@MainActor
@Observable
final class ListLegendState {
    static let shared = ListLegendState()
    /// The legend is up.
    private(set) var isShown = false
    /// How long ⌥ must be held before the legend shows.
    static let holdDelay: TimeInterval = 0.35

    @ObservationIgnored private var monitor: Any?
    /// Hosts on screen: a list that swaps its body (empty to rows) can appear before the old one
    /// disappears, so the monitor goes only when the last host leaves.
    @ObservationIgnored private var hosts = 0
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored var isActive: @MainActor () -> Bool = { false }

    private init() {}

    func install(isActive: @escaping @MainActor () -> Bool) {
        self.isActive = isActive
        hosts += 1
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func uninstall() {
        hosts = max(0, hosts - 1)
        guard hosts == 0 else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hide()
    }

    /// Shows the legend at once (the snapshot of the legend; the app path is the ⌥ hold).
    func showNow() {
        pending?.cancel()
        pending = nil
        isShown = true
    }

    func hide() {
        pending?.cancel()
        pending = nil
        if isShown { isShown = false }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // Only ⌥ alone, only in the main window (not Settings, a panel or a popover).
        guard event.type == .flagsChanged, flags == .option, event.window === NSApp.mainWindow, isActive() else { hide(); return }
        guard pending == nil, !isShown else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending != nil, self.isActive() else { return }
                self.pending = nil
                self.isShown = true
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }
}

extension View {
    /// Shows the key legend over this view while ⌥ is held and `isActive()` is true.
    func listKeyLegend(isActive: @escaping @MainActor () -> Bool) -> some View {
        modifier(ListKeyLegendHost(isActive: isActive))
    }
}

private struct ListKeyLegendHost: ViewModifier {
    let isActive: @MainActor () -> Bool
    @State private var state = ListLegendState.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if state.isShown {
                    ListKeyLegend()
                        .padding(.bottom, Space.x6)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.reduceMotion ? nil : Motion.curve(Motion.fast), value: state.isShown)
            .onAppear { state.install(isActive: isActive) }
            .onDisappear { state.uninstall() }
    }
}
