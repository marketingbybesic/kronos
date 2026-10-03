import Foundation

/// The decisions of the global quick add panel (⌃⌥K) that do not need AppKit: what a Return key
/// does, whether closing gives focus back to the app the panel was opened over, when the syntax
/// legend opens on its own, and where the acknowledgement says the task went. Pure, so the
/// tables in `QuickAddPolicyTests` state every case by hand.
public enum QuickAddPolicy {

    /// The Return chords of the panel. Shift-Return never gets here (it starts a new line).
    public enum ReturnKey: Sendable { case plain, command, option }

    public enum ReturnAction: Equatable, Sendable {
        /// Add the entry, then close the panel (one thought, the common case).
        case addAndClose
        /// Add, empty the field (text and pills) and stay open for the next thought.
        case addAndStay
        /// Add, empty only the text; the pills and the Waiting toggle stay (a batch into one project).
        case addAndKeepPills
        /// Nothing typed: Return closes the panel.
        case close
        /// Nothing typed and a chord that means "keep going": nothing happens.
        case ignore
    }

    /// ⏎ = add and close, ⌘⏎ = add and stay, ⌥⏎ = add and keep the pills; ⏎ on an empty field
    /// closes. Only the quick add panel works this way; every other entry surface keeps
    /// "Return adds and clears".
    public static func onReturn(_ key: ReturnKey, hasText: Bool) -> ReturnAction {
        switch (key, hasText) {
        case (.plain, true): return .addAndClose
        case (.command, true): return .addAndStay
        case (.option, true): return .addAndKeepPills
        case (.plain, false): return .close
        case (.command, false), (.option, false): return .ignore
        }
    }

    /// Why the panel is closing.
    public enum CloseReason: Sendable {
        /// Esc, Return or the hotkey again: the person is done here.
        case finished
        /// The panel lost key status because the person clicked into another app or window.
        case resignedKey
    }

    /// Focus goes back to the app the panel was opened over only when the person finished in
    /// the panel. A click elsewhere already chose where focus goes; activating the previous
    /// app then would steal that click.
    public static func reactivatesPreviousApp(_ reason: CloseReason) -> Bool {
        reason == .finished
    }

    /// How many adds the syntax legend opens by itself for, so the grammar is seen before it
    /// is needed. After that it opens only when the person asks ("Show syntax").
    public static let legendAutoOpenAdds = 3

    public static func legendOpens(pinned: Bool, addsSoFar: Int) -> Bool {
        pinned || addsSoFar < legendAutoOpenAdds
    }

    /// Where the acknowledgement says the new task went.
    public enum Destination: Equatable, Sendable {
        case project(String)
        case area(String)
        case waiting
        case day(Int)
        case inbox
    }

    /// A named project or area wins; then a waiting task; then a dated task (its day);
    /// everything else is in the Inbox.
    public static func destination(projectName: String?, areaName: String?, isWaiting: Bool,
                                   dueDay: Int?) -> Destination {
        if let projectName, !projectName.isEmpty { return .project(projectName) }
        if let areaName, !areaName.isEmpty { return .area(areaName) }
        if isWaiting { return .waiting }
        if let dueDay { return .day(dueDay) }
        return .inbox
    }
}
