// Kronos/List/TaskListScreen+AgentKeys.swift
// Kronos v1.2 Phase 2 slice C3: ⌃⌘H "Hand off…", ⌃⇧⌘H "Hand off and run", ⌘. "Stop agent" — one
// dedicated `.onKeyPress` in TaskListScreen.swift calls into `handleAgentKey` below. These three
// all carry ⌘ (Control too, for H): `ListKeyGrammar.action` explicitly refuses any press with
// Command/Option/Control held ("those are menu chords" — ListKeyGrammar.swift), so they are
// wired separately here rather than through the plain single-letter grammar `list.snooze` etc
// already use.
import SwiftUI
import KronosCore

extension TaskListScreen {
    /// Returns true when the press was one of the three agent keys (consumed either way, even
    /// when there is nothing selected to act on — matching every other list key's own `guard`).
    func handleAgentKey(_ press: KeyPress, _ ctx: ListContext) -> Bool {
        guard !Self.isTyping else { return false }
        let mods = press.modifiers
        switch press.characters.lowercased() {
        case "h":
            guard mods.contains(.control), mods.contains(.command) else { return false }
            AgentKeyActions.handoff(model, andRun: mods.contains(.shift))
            return true
        case ".":
            guard mods.contains(.command), !mods.contains(.control), !mods.contains(.option) else { return false }
            AgentKeyActions.stopSelectedRun(model)
            return true
        default:
            return false
        }
    }
}
