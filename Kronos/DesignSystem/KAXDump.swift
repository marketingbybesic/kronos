// Kronos/DesignSystem/KAXDump.swift
// Accessibility dump for the design tools (scripts/design/ax-check.mjs): when
// `KRONOS_SNAPSHOT_AXDUMP=<out.json>` is set, a snapshot run writes its own accessibility tree as
// a JSON array of {role, title, description, help, value, frame{x,y,width,height}} (points); `help`
// is the tooltip text (AXHelp), so "every icon control has a tooltip" is checked on the real tree.
// The tree is read from a CHILD process (this same executable, started with
// `KRONOS_AXWALK_PID=<pid>`), the way any assistive app reads it: asking the Accessibility server
// about this very process from inside it stalled on SwiftUI elements (measured, both from a
// background thread and with the main loop pumped), while the snapshot process itself keeps its
// run loop free to answer. Needs the terminal to hold Accessibility permission; without it the
// dump fails loudly instead of writing an empty file.
// With a window given to `start`, only that window's subtree is walked (the harness window that
// holds the screen under test), so the process's own chrome, a stray on-screen window or the menu
// bar can never fail a hit-target or label check. A window that cannot be found is an error.
// Gallery tool: DesignGallerySnapshot calls `start(onExit:)` after its render and
// `walkIfChild()` first thing. The app's snapshot harness does the same two calls.
import AppKit
import ApplicationServices

@MainActor
public enum KAXDump {
    /// The output path asked for, if any.
    public static var requestedPath: String? {
        let p = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT_AXDUMP"]
        return (p?.isEmpty ?? true) ? nil : p
    }

    /// In the child: walks the parent's tree, writes the JSON and exits (0 on success). In any
    /// other process it returns at once.
    public static func walkIfChild() {
        guard let raw = ProcessInfo.processInfo.environment["KRONOS_AXWALK_PID"], let pid = pid_t(raw) else { return }
        guard let path = requestedPath else { exit(fail("AXDUMP: no output path")) }
        guard AXIsProcessTrusted() else {
            exit(fail("AXDUMP: the terminal needs Accessibility permission (AXIsProcessTrusted is false)"))
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
        var rows: [[String: Any]] = []
        if let spec = ProcessInfo.processInfo.environment["KRONOS_AXWALK_WINDOW"] {
            let wanted = spec.split(separator: ",").compactMap { Double($0) }
            guard wanted.count == 3 else { exit(fail("AXDUMP: bad window spec \(spec)")) }
            let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            let match = windows.filter { window in
                guard let f = frame(of: window) else { return false }
                return abs(f.origin.x - wanted[0]) < 2 && abs(f.size.width - wanted[1]) < 2 && abs(f.size.height - wanted[2]) < 2
            }
            guard let target = match.first else { exit(fail("AXDUMP: the harness window is not in the accessibility tree")) }
            collect(target, into: &rows, depth: 0)
        } else {
            collect(app, into: &rows, depth: 0)
        }
        guard !rows.isEmpty else { exit(fail("AXDUMP: accessibility tree is empty")) }
        do {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
            print("axdump \(path) elements=\(rows.count)")
            exit(0)
        } catch {
            exit(fail("AXDUMP: \(error)"))
        }
    }

    /// In the snapshot process, after the render is on screen: starts the child walker and calls
    /// `onExit` with its exit status. Returns false when no dump was asked for (nothing started).
    /// The caller keeps its run loop running until `onExit`.
    @discardableResult
    public static func start(window: NSWindow? = nil, onExit: @escaping @MainActor @Sendable (Int32) -> Void) -> Bool {
        guard requestedPath != nil, let exe = Bundle.main.executablePath else { return false }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: exe)
        child.arguments = Array(CommandLine.arguments.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["KRONOS_AXWALK_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        if let window {
            let f = window.frame
            env["KRONOS_AXWALK_WINDOW"] = "\(f.origin.x),\(f.size.width),\(f.size.height)"
        }
        child.environment = env
        child.terminationHandler = { p in
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status) } }
        }
        do {
            try child.run()
        } catch {
            _ = fail("AXDUMP: could not start the walker: \(error)")
            onExit(1)
        }
        return true
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        // Type IDs checked above, so these casts cannot fail.
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func collect(_ e: AXUIElement, into rows: inout [[String: Any]], depth: Int) {
        guard depth < 60 else { return }
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        // Off-screen or not-yet-laid-out elements can report an infinite frame; JSON cannot hold it.
        let raw = frame(of: e) ?? .zero
        let f = [raw.origin.x, raw.origin.y, raw.size.width, raw.size.height].allSatisfy(\.isFinite) ? raw : .zero
        var value = ""
        if let v = attr(e, kAXValueAttribute) {
            if let s = v as? String { value = s } else if let n = v as? NSNumber { value = n.stringValue }
        }
        // The application element itself is not a control; its windows and their content are.
        if role != (kAXApplicationRole as String) {
            rows.append([
                "role": role,
                "title": attr(e, kAXTitleAttribute) as? String ?? "",
                "description": attr(e, kAXDescriptionAttribute) as? String ?? "",
                "help": attr(e, kAXHelpAttribute) as? String ?? "",
                "value": value,
                "frame": ["x": f.origin.x, "y": f.origin.y, "width": f.size.width, "height": f.size.height],
            ])
        }
        // A scroller's arrow and page parts are AppKit's own chrome, not Kronos controls.
        guard role != (kAXScrollBarRole as String) else { return }
        for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            collect(child, into: &rows, depth: depth + 1)
        }
    }
}
