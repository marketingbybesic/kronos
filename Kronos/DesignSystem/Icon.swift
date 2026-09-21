// Kronos/DesignSystem/Icon.swift
// One glyph wrapper so every icon in the app goes through the same size/weight/color
// rules. Lucide-style names resolve through a map to the closest SF Symbol, so callers
// never change if a Lucide asset catalog lands later. A name not in the map but that IS a
// real SF Symbol (e.g. KArea.icon stores raw names like "square.grid.2x2") resolves
// directly. Every resolution is VERIFIED against the running system: a mapped symbol that
// does not exist here renders the fallback, and `Icon.unresolved(_:)` reports it, so a
// blank or wrong glyph can never ship silently again (the old map pointed "archive" and
// "gavel" at symbols that do not exist and "receipt" at a macOS 15 one).
// Usage: Icon("folder", size: Metrics.iconM).foregroundStyle(Tok.textSecondary)
import SwiftUI
import AppKit

public struct Icon: View {
    let name: String
    var size: CGFloat
    var weight: Font.Weight

    public init(_ name: String, size: CGFloat = Metrics.iconM, weight: Font.Weight = .regular) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        Group {
            if name == "tooth" {
                // SF Symbols has no tooth; drawn to the same optical weight as a regular symbol.
                KToothShape()
                    .stroke(style: StrokeStyle(lineWidth: max(1, size * 0.085), lineCap: .round, lineJoin: .round))
                    .padding(size * 0.1)
            } else {
                Image(systemName: Self.symbol(for: name))
                    .font(.system(size: size * 0.86, weight: weight))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // the enclosing control supplies the label
    }

    static let fallbackSymbol = "questionmark.folder"
    /// Names drawn by this file instead of SF Symbols.
    static let customDrawn: Set<String> = ["tooth"]

    /// Lucide name -> SF Symbol, else the raw name if it is a real SF Symbol, else the
    /// fallback. Never maps to an exclamation glyph — this app never signals urgency with
    /// an alarm symbol.
    static func symbol(for lucideName: String) -> String {
        let candidate = map[lucideName] ?? lucideName
        return exists(candidate) ? candidate : fallbackSymbol
    }

    /// The subset of `names` that would render the fallback glyph on this machine.
    static func unresolved(_ names: [String]) -> [String] {
        names.filter { !customDrawn.contains($0) && symbol(for: $0) == fallbackSymbol }
    }

    /// Every Lucide-style name the map understands, alphabetical — so the gallery's
    /// icon table (and anyone auditing coverage) doesn't need its own copy of the list.
    static var allMappedNames: [String] { map.keys.sorted() }

    private static var existsCache: [String: Bool] = [:]
    private static func exists(_ symbol: String) -> Bool {
        if let hit = existsCache[symbol] { return hit }
        let found = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        existsCache[symbol] = found
        return found
    }

    // Every value below is available on macOS 14.0 (checked against the system's
    // CoreGlyphs name_availability table, not from memory).
    private static let map: [String: String] = [
        // App chrome
        "inbox": "tray", "sun": "sun.max", "calendar-days": "calendar", "calendar": "calendar",
        "clock": "clock", "alarm-clock": "alarm", "hourglass": "hourglass", "repeat": "repeat",
        "list-ordered": "list.number", "archive": "archivebox", "search": "magnifyingglass",
        "filter": "line.3.horizontal.decrease.circle", "sliders": "slider.horizontal.3",
        "chevron-right": "chevron.right", "chevron-down": "chevron.down", "chevron-up": "chevron.up",
        "chevron-left": "chevron.left", "chevron-up-down": "chevron.up.chevron.down",
        "arrow-up": "arrow.up", "arrow-down": "arrow.down", "arrow-left": "arrow.left", "arrow-right": "arrow.right",
        "plus": "plus", "minus": "minus", "x": "xmark", "check": "checkmark", "check-square": "checkmark.square",
        // No "alert"/"alert-triangle" entries: nothing in this app signals urgency with an
        // alarm glyph — priority is shape-only (KPriorityIndicator), and "!" is banned.
        "grip-vertical": "line.3.horizontal", "panel-right": "sidebar.right", "eye": "eye", "eye-off": "eye.slash",
        "bookmark-plus": "bookmark.fill", "more-horizontal": "ellipsis", "trash": "trash", "pencil": "pencil",
        "play": "play.fill", "copy": "doc.on.doc", "tag": "tag", "settings": "gearshape", "command": "command", "keyboard": "keyboard",
        "download": "arrow.down.circle", "upload": "arrow.up.circle", "refresh": "arrow.clockwise",
        "undo": "arrow.uturn.backward", "redo": "arrow.uturn.forward", "info": "info.circle",
        "shield": "shield", "gavel": "checkmark.seal", "plug": "powerplug", "book-open": "book",
        "chart-line": "chart.xyaxis.line",
        // Colour modes (KChromaModeSwitch)
        "circle-dot": "smallcircle.filled.circle", "moon": "moon", "circle": "circle",
        // ProjectIconSet — work
        "briefcase": "briefcase", "building": "building.2", "building-2": "building.2",
        "landmark": "building.columns", "folder": "folder", "target": "target", "rocket": "paperplane",
        "clipboard": "list.clipboard", "chart-pie": "chart.pie",
        // money
        "wallet": "wallet.pass", "euro": "eurosign.circle", "credit-card": "creditcard", "banknote": "banknote",
        "receipt": "doc.text", "trending-up": "chart.line.uptrend.xyaxis", "shopping-cart": "cart", "scale": "scalemass",
        // people
        "users": "person.2", "user": "person", "heart": "heart", "message-square": "message", "phone": "phone",
        "mail": "envelope", "megaphone": "megaphone", "graduation-cap": "graduationcap",
        // food
        "utensils": "fork.knife", "coffee": "cup.and.saucer", "wine": "wineglass", "carrot": "carrot",
        "fish": "fish", "leaf": "leaf", "cake": "birthday.cake", "flame": "flame",
        // media
        "camera": "camera", "video": "video", "music": "music.note", "palette": "paintpalette", "image": "photo",
        "film": "film", "mic": "mic", "pen-tool": "pencil.tip",
        // web
        "globe": "globe", "link": "link", "code": "chevron.left.forwardslash.chevron.right", "terminal": "terminal",
        "server": "server.rack", "database": "cylinder", "cloud": "cloud", "monitor": "display",
        // home
        "home": "house", "sofa": "sofa", "bed": "bed.double", "key": "key", "lamp": "lamp.desk",
        "hammer": "hammer", "wrench": "wrench", "paw": "pawprint",
        // health ("tooth" is drawn by KToothShape; its entry keeps the name a lintable map key)
        "tooth": "mouth", "stethoscope": "stethoscope", "pill": "pills", "dumbbell": "dumbbell", "first-aid": "cross.case",
        "brain": "brain", "activity": "waveform.path.ecg", "run": "figure.run",
        // travel
        "car": "car", "plane": "airplane", "train": "tram", "bike": "bicycle", "ship": "ferry", "map": "map",
        "suitcase": "suitcase", "mountain": "mountain.2",
        // misc
        "star": "star", "flag": "flag", "bookmark": "bookmark", "zap": "bolt", "lightbulb": "lightbulb",
        "sparkles": "sparkles", "gift": "gift", "puzzle": "puzzlepiece",
    ]
}

/// A molar in outline: two-lobed crown, two roots. Unit-square path, stroked by `Icon`.
struct KToothShape: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var p = Path()
        p.move(to: pt(0.50, 0.17))
        p.addCurve(to: pt(0.20, 0.10), control1: pt(0.40, 0.08), control2: pt(0.28, 0.04))
        p.addCurve(to: pt(0.16, 0.52), control1: pt(0.04, 0.20), control2: pt(0.07, 0.40))
        p.addCurve(to: pt(0.29, 0.93), control1: pt(0.23, 0.63), control2: pt(0.21, 0.84))
        p.addCurve(to: pt(0.40, 0.84), control1: pt(0.34, 0.99), control2: pt(0.39, 0.94))
        p.addCurve(to: pt(0.50, 0.62), control1: pt(0.41, 0.72), control2: pt(0.43, 0.62))
        p.addCurve(to: pt(0.60, 0.84), control1: pt(0.57, 0.62), control2: pt(0.59, 0.72))
        p.addCurve(to: pt(0.71, 0.93), control1: pt(0.61, 0.94), control2: pt(0.66, 0.99))
        p.addCurve(to: pt(0.84, 0.52), control1: pt(0.79, 0.84), control2: pt(0.77, 0.63))
        p.addCurve(to: pt(0.80, 0.10), control1: pt(0.93, 0.40), control2: pt(0.96, 0.20))
        p.addCurve(to: pt(0.50, 0.17), control1: pt(0.72, 0.04), control2: pt(0.60, 0.08))
        p.closeSubpath()
        return p
    }
}
