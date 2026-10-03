// Kronos/Impuls/LeftOffText.swift
// The one "where I left off" line shown on the Now card and the Impuls card: the next open step,
// else the first line of the notes. Foundation only (compiled by scripts/impuls-defaults-selftest.swift).

import Foundation

enum LeftOffText {
    /// nil when there is nothing to say, or when the only candidate would repeat the hero or the
    /// title already on screen.
    static func pick(nextStep: String?, notes: String, hero: String, title: String, maxLength: Int = 90) -> String? {
        let shown = [hero, title].map(normalised)
        func usable(_ s: String) -> Bool { !s.isEmpty && !shown.contains(normalised(s)) }

        if let step = nextStep?.trimmingCharacters(in: .whitespacesAndNewlines), usable(step) {
            return clipped(step, maxLength)
        }
        for raw in notes.split(whereSeparator: \.isNewline) {
            let line = stripMarker(String(raw).trimmingCharacters(in: .whitespaces))
            if line.isEmpty || line.contains("link://") || line.contains("notes://") { continue }
            if usable(line) { return clipped(line, maxLength) }
        }
        return nil
    }

    private static func normalised(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Leading list or heading markers are not part of the sentence.
    private static func stripMarker(_ s: String) -> String {
        var out = Substring(s)
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "• ", "### ", "## ", "# "] where out.hasPrefix(marker) {
            out = out.dropFirst(marker.count)
            break
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func clipped(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        let head = String(s.prefix(max))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut + "…"
    }
}
