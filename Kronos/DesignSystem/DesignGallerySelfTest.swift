// Kronos/DesignSystem/DesignGallerySelfTest.swift
// Hand-written expectation tables for the design system's pure decisions (colour mode, ring and
// label contrast, type floor, undo pill actions, motion switches, key cap labels, swatch names).
// Runs from the standalone gallery tool, so it needs no app target:
//   swiftc -parse-as-library -o build/gallery-shot scripts/gallery-shot-main.swift Kronos/DesignSystem/*.swift
//   KRONOS_DS_SELFTEST=1 ./build/gallery-shot build/ds-selftest.png tokens
// prints "DS SELFTEST OK cases=N" and exits 0. KRONOS_DS_SELFTEST=break inverts every
// expectation (positive control): every case must then fail, printed as "DS SELFTEST BROKEN".
// Expected values are written by hand from the specs (WCAG formulas worked on paper, HIG 10 pt
// floor, docs/dev/60-66), never computed by the code under test.
import SwiftUI
import AppKit

@MainActor
enum DesignSelfTest {
    private struct Case {
        let name: String
        let passed: Bool
    }

    static func runAndExit(breaking: Bool) -> Never {
        var cases: [Case] = []
        func check(_ name: String, _ condition: Bool) {
            cases.append(Case(name: name, passed: breaking ? !condition : condition))
        }

        // Focus colour mode is all neutral: every accent resolves to white (Tok.textPrimary
        // itself); Full keeps the chosen colour. Hex values are the stored-data form.
        for hex in ["B483FF", "#5B5BFF", "F2C94C", "123456"] {
            check("focus resolves \(hex) to white", Accent.resolve(hex, mode: .focus) == Tok.textPrimary)
            check("full keeps \(hex)", Accent.resolve(hex, mode: .full) != Tok.textPrimary)
        }
        check("full with no accent is white", Accent.resolve(nil, mode: .full) == Tok.textPrimary)
        check("full with garbage is white", Accent.resolve("zzz", mode: .full) == Tok.textPrimary)

        // Label on an accent fill: black when black has the higher WCAG ratio. Luminances and
        // ratios worked by hand: B483FF L 0.332 -> black 7.63 vs white 2.75; 5B5BFF L 0.169 ->
        // black 4.39 vs white 4.79; 9D4CFF L 0.196 -> black 4.91 vs white 4.28; white -> black.
        let labels: [(hex: String, black: Bool)] = [("B483FF", true), ("5B5BFF", false), ("9D4CFF", true),
                                                     ("FF2FD8", true), ("FFFFFF", true), ("000080", false)]
        for row in labels {
            let wantsBlack = Accent.onFill(Color(hexString: row.hex)) == .black
            check("label on \(row.hex) is \(row.black ? "black" : "white")", wantsBlack == row.black)
        }

        // Ring opacity: palette swatches keep the base 0.80 (electric 5B5BFF reaches 3.10:1 at
        // 0.80); a darker custom colour is raised. 4040FF at 0.80 -> 2.49:1, reaches 3:1 at 0.92;
        // 2020A0 fails even solid (1.78:1) so it is drawn at full opacity and lifted toward white.
        check("ring B483FF stays 0.80", abs(KRing.opacity(for: Color(hexString: "B483FF")) - 0.80) < 0.001)
        check("ring 5B5BFF stays 0.80", abs(KRing.opacity(for: Color(hexString: "5B5BFF")) - 0.80) < 0.001)
        let custom = KRing.opacity(for: Color(hexString: "4040FF"))
        check("ring 4040FF raised to 0.92", abs(custom - 0.92) < 0.0151)
        check("ring 2020A0 at full opacity", KRing.opacity(for: Color(hexString: "2020A0")) == 1.0)
        let lifted = KColorMath.srgb(KRing.color(Color(hexString: "2020A0"), increasedContrast: false))
        check("ring 2020A0 lifted to 3:1", KColorMath.contrastOnBlack(lifted) >= 3.0)
        check("white accent ring is focusRing", KRing.color(Tok.textPrimary, increasedContrast: false) == Tok.focusRing)

        // Type floor: macOS minimum 10 pt at every text size (S 0.92, M 1.0, L 1.1).
        let saved = DSScale.text
        let sizes: [(scale: CGFloat, base: CGFloat, expected: CGFloat)] = [
            (0.92, 10, 10), (1.0, 10, 10), (1.1, 10, 11), (0.92, 13, 11.96), (0.92, 11, 10.12),
        ]
        for row in sizes {
            DSScale.text = row.scale
            check("size \(row.base) at \(row.scale) = \(row.expected)", abs(Typo.size(row.base) - row.expected) < 0.001)
        }
        DSScale.text = saved

        // Undo pill: the primary action runs once and clears the pill; a notice has none; a title
        // without an action (or the reverse) shows nothing.
        let center = UndoToastCenter.shared
        var started = 0
        center.show("Done", primaryTitle: "Start", onPrimary: { started += 1 })
        check("pill carries the primary title", center.current?.primaryTitle == "Start")
        check("performPrimary runs it", center.performPrimary() && started == 1)
        check("performPrimary clears the pill", center.current == nil)
        check("second performPrimary is a no-op", !center.performPrimary() && started == 1)
        center.showNotice("Refused")
        check("notice has no primary", center.current?.primaryTitle == nil && !center.performPrimary())
        check("title without action is dropped", ListUndoState(message: "m", primaryTitle: "Start").primaryTitle == nil)
        center.dismiss()

        // Motion: the ripple never runs under Reduce Motion; KRONOS_REDUCE_MOTION=1 turns the
        // reduced path on without the system setting.
        check("ripple runs normally", Motion.ripples(reduceMotion: false))
        check("ripple skipped under Reduce Motion", !Motion.ripples(reduceMotion: true))
        let systemRM = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setenv("KRONOS_REDUCE_MOTION", "1", 1)
        check("KRONOS_REDUCE_MOTION=1 reduces motion", Motion.reduceMotion)
        unsetenv("KRONOS_REDUCE_MOTION")
        check("without the env var Motion follows the system", Motion.reduceMotion == systemRM)
        check("ripple duration is 260 ms", abs(Motion.completeRipple - 0.26) < 0.0001)

        // Increase Contrast switch for snapshots.
        setenv("KRONOS_SNAPSHOT_CONTRAST", "increased", 1)
        check("KRONOS_SNAPSHOT_CONTRAST forces IC", KContrast.isIncreased(.standard))
        check("forced IC strengthens the white selection", KSelection.fill(Tok.textPrimary) == Tok.selectedFillIC)
        unsetenv("KRONOS_SNAPSHOT_CONTRAST")
        check("IC off by default in a test run", !KContrast.forced && KSelection.fill(Tok.textPrimary) == Tok.selectedFill)

        // Key caps: Escape prints "esc"; everything else prints itself.
        check("escape cap prints esc", KKeyCap.label(for: "\u{238B}") == "esc")
        check("command cap unchanged", KKeyCap.label(for: "⌘") == "⌘")

        // Swatch names: every swatch of both palettes shows its own catalog entry
        // ("accent.swatch.<name>", looked up here directly), never the capitalised data key.
        let names = KProjectPalette.swatches.map(\.name) + AccentPalette.swatches.map(\.name)
        check("19 distinct swatch names", Set(names).count == 19)
        for name in names {
            let key = "accent.swatch." + name
            let catalog = Bundle.main.localizedString(forKey: key, value: key, table: nil)
            check("swatch \(name) shows its catalog entry", KProjectPalette.displayName(for: name) == catalog)
        }

        let failures = cases.filter { !$0.passed }
        if breaking {
            if failures.count == cases.count {
                print("DS SELFTEST BROKEN failures=\(failures.count) cases=\(cases.count)")
                exit(1)
            }
            for c in cases where c.passed { print("NOT BROKEN: \(c.name)") }
            print("DS SELFTEST BREAK INCOMPLETE")
            exit(2)
        }
        for f in failures { print("FAIL: \(f.name)") }
        if failures.isEmpty {
            print("DS SELFTEST OK cases=\(cases.count)")
            exit(0)
        }
        print("DS SELFTEST FAILED failures=\(failures.count) cases=\(cases.count)")
        exit(1)
    }
}
