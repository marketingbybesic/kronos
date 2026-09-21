// KronosCore/AI — the extraction pipeline.
//
// Turns a raw AIResponse.text into a decoded, Codable value: strips a
// leading/trailing code fence, slices from the first `{` to the last `}` to
// absorb prose wrapping, then strict-decodes. This is the ONE place every
// prompt's reply passes through before its DTO-specific validation runs.

import Foundation

public enum OutputExtraction {

    /// Fence strip + brace slice + strict decode, in that order.
    /// `finish_reason == .length` is
    /// handled earlier by `AIResponse.validated()` and never reaches here.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let sliced = braceSlice(stripFences(text))
        guard let data = sliced.data(using: .utf8) else {
            throw AIError.badJSON(prefix: String(text.prefix(200)))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIError.badJSON(prefix: String(text.prefix(200)))
        }
    }

    /// Removes a leading ```json / ``` fence and a trailing ``` fence, if
    /// present. Tolerant of a language tag or none.
    static func stripFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            } else {
                s = String(s.dropFirst(3))
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Takes the substring from the first `{` to the last `}`, which absorbs
    /// preamble prose ("Here is the JSON:") and trailing commentary. Returns
    /// the input unchanged if no brace pair is found (the decode will then
    /// fail on its own and produce a `badJSON` error).
    static func braceSlice(_ text: String) -> String {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last else {
            return text
        }
        return String(text[first...last])
    }
}
