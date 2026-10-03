// Kronos/QuickAdd/QuickAddContextLive.swift
// The system side of context-aware quick add (KronosCore QuickAdd/QuickAddContext.swift holds
// the orchestration and the scripts): Apple Events permission reads, osascript runs with a hard
// timeout, and the Accessibility read of the selected text. Plus the panel's observable context
// state: the chips it shows, the consent chip, and what a submit attaches.
//
// Never a prompt by itself: the Automation answer is read with askUserIfNeeded false; the only
// call with true comes from the consent chip's click. The selected text is read only when the
// app already holds the Accessibility permission. Under a snapshot, the live UI test or a
// scratch store the environment is `NullQuickAddContextEnvironment` (nothing is read) unless
// the live test injects its own.
import AppKit
import ApplicationServices
import KronosCore

/// Live system reads. Every call runs off the main thread and gives up on its own timeout.
struct LiveQuickAddContextEnvironment: QuickAddContextEnvironment {

    func automation(_ bundleID: String, ask: Bool) async -> QuickAddAutomation {
        await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask) // prompt-ok: ask is true only from the consent chip's click
            switch Int(status) {
            case 0: return QuickAddAutomation.granted
            // Not asked yet; procNotFound when the system could not answer for a target that is
            // starting or quitting: treat as "ask first", never as a denial.
            case -1744, -600: return .notAsked
            default: return .denied
            }
        }.value
    }

    func runScript(_ source: String, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            let once = ContextResumeOnce(continuation)
            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                once.resume(proc.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
            }
            do { try process.run() } catch { once.resume(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                once.resume(nil)
            }
        }
    }

    func selectedText(pid: Int32) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            // No prompt here: without the permission there is simply no selected text.
            guard AXIsProcessTrusted() else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
            var selected: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success
            else { return nil }
            return selected as? String
        }.value
    }
}

/// Reads nothing and never asks: snapshots, the live UI test and scratch stores.
struct NullQuickAddContextEnvironment: QuickAddContextEnvironment {
    func automation(_ bundleID: String, ask: Bool) async -> QuickAddAutomation { .denied }
    func runScript(_ source: String, timeout: TimeInterval) async -> String? { nil }
    func selectedText(pid: Int32) async -> String? { nil }
}

/// Resumes once: the process's exit and the timeout race for the same continuation.
private final class ContextResumeOnce: @unchecked Sendable {
    private let continuation: CheckedContinuation<String?, Never>
    private let lock = NSLock()
    private var done = false
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func resume(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: value)
    }
}

/// The app the panel was opened over, as the reader needs it.
struct QuickAddFrontApp: Equatable {
    var bundleID: String?
    var pid: Int32
    var name: String
}

/// What the panel shows of the front app's context, and what a submit attaches.
@MainActor
@Observable
final class QuickAddContextState {
    /// Link chips (web page, mail, note, files), each removable.
    private(set) var links: [ContextLink] = []
    /// The source whose Automation answer is not known yet: the panel shows a chip that asks.
    private(set) var consent: QuickAddContextSource?
    /// The app that source belongs to (its name goes into the consent chip).
    private(set) var front: QuickAddFrontApp?
    private(set) var isReading = false

    @ObservationIgnored private let environment: QuickAddContextEnvironment
    /// Called with a starting title once one is read (the panel decides whether to use it).
    @ObservationIgnored var onPrefill: (String) -> Void = { _ in }
    /// The consent chip's click (the controller keeps the panel open through the system prompt).
    @ObservationIgnored var askConsent: () -> Void = {}

    init(environment: QuickAddContextEnvironment, front: QuickAddFrontApp? = nil) {
        self.environment = environment
        self.front = front
    }

    /// A ready-made state for snapshots (no reading).
    init(links: [ContextLink], consent: QuickAddContextSource? = nil, front: QuickAddFrontApp? = nil) {
        self.environment = NullQuickAddContextEnvironment()
        self.links = links
        self.consent = consent
        self.front = front
    }

    /// Reads the front app once. `ask` true only from the consent chip.
    func read(ask: Bool = false) async {
        guard let front else { return }
        isReading = true
        let context = await QuickAddContextReader.read(bundleID: front.bundleID, pid: front.pid,
                                                       environment: environment, ask: ask)
        isReading = false
        apply(context)
    }

    func apply(_ context: QuickAddContext) {
        let files = context.filePaths.map { FileDropPasteboard.fields(for: URL(fileURLWithPath: $0)).contextLink }
        links = (context.links + files).filter { !$0.reference.isEmpty }
        consent = context.consent
        if let prefill = context.prefill { onPrefill(prefill) }
    }

    func remove(_ link: ContextLink) {
        links.removeAll { $0.kind == link.kind && $0.reference == link.reference }
    }

    /// After an add that empties the field: the context belonged to that task.
    func clear() {
        links = []
        consent = nil
    }
}
