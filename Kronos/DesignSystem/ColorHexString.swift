// Project and area colours are stored in the model as hex STRINGS ("#5B8DEF"). This is the one
// place that turns them into a Color — user data colour, the only hue Kronos ever shows.
// (Two UI leaves each wrote a private copy in isolation; unified here at merge.)

import SwiftUI

public extension Color {
    /// Parses "#RRGGBB" or "RRGGBB". An unparseable string falls back to the neutral tertiary
    /// text tone rather than an arbitrary colour, so bad data stays quiet.
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { self = Tok.textTertiary; return }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }
}
