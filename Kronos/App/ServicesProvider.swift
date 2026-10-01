// Kronos/App/ServicesProvider.swift
// Services menu: "Add to Kronos" and "Capture in Kronos" on selected text in any app.
// The menu entries are declared in project.yml (NSServices); NSMessage names below match.
import AppKit
import KronosCore

final class ServicesProvider: NSObject {
    private let model: AppModel
    init(model: AppModel) { self.model = model }

    /// First line is the task title, the rest becomes its notes.
    @objc func addToKronos(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string) else { return }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first,
              let title = KronosURLParser.clean(first, cap: KronosURLParser.maxTitle, singleLine: true) else { return }
        let rest = KronosURLParser.clean(lines.dropFirst().joined(separator: "\n"), cap: KronosURLParser.maxNotes, singleLine: false)
        MainActor.assumeIsolated {
            guard AppDelegate.shared?.launchFailure == nil else { return }
            URLSchemeRouter.add(title: title, notes: rest, project: nil, due: nil, model: model)
        }
    }

    @objc func captureInKronos(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let raw = pboard.string(forType: .string),
              let text = KronosURLParser.clean(raw, cap: KronosURLParser.maxCapture, singleLine: false) else { return }
        MainActor.assumeIsolated {
            guard AppDelegate.shared?.launchFailure == nil else { return }
            model.openCapture(with: text)
            AppDelegate.shared.bringForward()
        }
    }
}
