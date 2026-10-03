// Kronos/List/RowAccessibility.swift
// How a list row reads aloud. One element per row (KListRow folds the row's children away), so
// VoiceOver reads the label as one sentence: "<title>, <project>, due <date>, <state>". A part
// the task does not have is left out, never read as an empty slot. Everything else a person may
// want to hear (priority, subtask progress, overdue) goes into the value, which VoiceOver reads
// after the label and which a person can skip by moving on.
// Foundation only, so scripts/a11y-selftest-rowlabel.swift compiles THIS file against a
// hand-written table; the caller passes already-localized pieces.
import Foundation

enum RowAccessibility {
    /// "<title>, <project>, due <date>, <state>". `due` is the whole phrase ("due Oct 3").
    static func label(title: String, project: String?, due: String?, state: String) -> String {
        join([title, project, due, state])
    }

    /// The extras after the label, in reading order; empty pieces are dropped.
    static func value(_ parts: [String?]) -> String { join(parts) }

    private static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
