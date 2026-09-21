// Kronos/DesignSystem/DesignGallerySnapshot.swift
// Renders DesignGallery to a PNG at 2x on a black background, for visual verification
// outside Xcode's own preview. Imports only SwiftUI/AppKit — the DesignSystem module
// must never depend on KronosCore, so this stays compilable standalone via `swiftc`
// (see scripts/gallery-shot-main.swift, which calls writePNG(to:)).
import SwiftUI
import AppKit

@MainActor
public enum DesignGallerySnapshot {
    /// `String(localized:)` resolves against `Bundle.main`, which for this bare
    /// command-line tool is just the folder containing the compiled `gallery-shot`
    /// binary — with no `en.lproj/Localizable.strings` there, every localized string
    /// in the design system renders as its raw catalog key (e.g. "ordo.title"
    /// instead of "Ordo"), which is a real visual defect in the gallery crops even
    /// though the actual app resolves correctly (it has a real bundle). Fixed by
    /// copying the Alpha build's already-compiled .strings tables (produced by the
    /// same gate's earlier `xcodebuild` step, see gate-app.mjs) next to wherever this
    /// binary is running from, once, before the first render. If no Alpha build
    /// product exists yet, this is a silent no-op and strings fall back to their key,
    /// same as before — never a hard failure of the snapshot tool.
    private static var didInstallStrings = false
    private static func installLocalizations() {
        guard !didInstallStrings else { return }
        didInstallStrings = true
        let fm = FileManager.default
        let searchRoots = ["build", "."]
        var appResources: String?
        for root in searchRoots {
            guard let dds = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for dd in dds where dd.hasPrefix("dd-") || dd == "build" {
                let candidate = "\(root)/\(dd)/Build/Products/Alpha/Kronos.app/Contents/Resources"
                if fm.fileExists(atPath: candidate) { appResources = candidate; break }
            }
            if appResources != nil { break }
        }
        guard let appResources else { return }
        let destDir = Bundle.main.bundlePath
        for lang in ["en", "hr"] {
            let src = "\(appResources)/\(lang).lproj"
            let dst = "\(destDir)/\(lang).lproj"
            guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { continue }
            try? fm.copyItem(atPath: src, toPath: dst)
        }
    }

    /// A bare command-line tool has no NSApplication run loop, which leaves
    /// ImageRenderer's underlying NSHostingView never laid out (renders empty pixels).
    /// This puts up a real (but never-ordered-front) window, spins the app's own run
    /// loop via a zero-delay timer so AppKit performs a real layout/display pass, then
    /// renders and terminates. This is the standard workaround for SwiftUI snapshotting
    /// from a CLI context.
    public static func writePNG(to path: String) {
        writePNG(view: AnyView(DesignGallery().content), width: 1000, to: path)
    }

    /// Renders an arbitrary section view (e.g. just the sidebar section) to its own
    /// PNG, for when the full gallery is too tall to review as one image.
    public static func writeSectionPNG<V: View>(_ view: V, width: CGFloat = 1000, to path: String) {
        writePNG(view: AnyView(view.padding(Space.x6).background(Tok.bg)), width: width, to: path)
    }

    private static func writePNG(view: AnyView, width: CGFloat, to path: String) {
        installLocalizations()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Leading-aligned on black: the crop used to centre the section between two strips of bare
        // (white) window background.
        let hosting = NSHostingView(rootView: view.frame(width: width, alignment: .topLeading).background(Tok.bg))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1900)

        // NSTextView's field editor (backing TextField/TextEditor) needs a real key
        // window to acquire a text-rendering context; a never-ordered window makes it
        // fall back to a "restricted glyph" placeholder. Position far off-screen and
        // make it key/front instead of invisible, so text fields render normally while
        // nothing is shown to the user.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(nil)

        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            // The Timer closure type is not statically MainActor-isolated, but it always
            // fires on the main run loop (this whole flow runs on it via app.run()), so
            // this is a sound assertion, not a workaround for a real data race.
            MainActor.assumeIsolated {
                render(hosting: hosting, window: window, app: app, path: path)
            }
        }
        app.run()
    }

    @MainActor
    private static func render(hosting: NSHostingView<some View>, window: NSWindow, app: NSApplication, path: String) {
        // AppKit hands first responder to the first focusable control of a key window, which drew
        // a keyboard-focus ring on whatever button happened to come first in every crop.
        window.makeFirstResponder(nil)
        let fitSize = hosting.fittingSize
        hosting.setFrameSize(fitSize)
        window.setContentSize(fitSize)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        // Capture pixels directly from the already-laid-out, already-keyed NSView
        // rather than handing hosting.rootView to a second, disconnected
        // ImageRenderer — that second pass instantiates a fresh SwiftUI tree with
        // no window/input context, which is what produces a "no entry" glyph
        // placeholder on every TextField/TextEditor.
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write("FAIL: could not create bitmap rep\n".data(using: .utf8)!)
            app.terminate(nil)
            return
        }
        rep.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        let scale = 2
        let pixelSize = NSSize(width: fitSize.width * CGFloat(scale), height: fitSize.height * CGFloat(scale))
        guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            FileHandle.standardError.write("FAIL: could not allocate scaled bitmap\n".data(using: .utf8)!)
            app.terminate(nil)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSColor.black.setFill()
        NSRect(origin: .zero, size: pixelSize).fill()
        rep.draw(in: NSRect(origin: .zero, size: pixelSize))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = scaled.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("FAIL: could not encode PNG\n".data(using: .utf8)!)
            app.terminate(nil)
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(Int(pixelSize.width))x\(Int(pixelSize.height)))")
        } catch {
            FileHandle.standardError.write("FAIL: \(error)\n".data(using: .utf8)!)
        }
        app.terminate(nil)
    }
}
