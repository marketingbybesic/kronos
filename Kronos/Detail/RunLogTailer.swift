// Kronos/Detail/RunLogTailer.swift
// Tails a Kronos-launched run's log file: the last 200 lines, re-read whenever the file is
// written to (DispatchSource on the fd, no polling). No existing precedent in this codebase for
// file watching — this is the first one, kept minimal: on every write event it just re-reads
// and re-truncates the whole file rather than tracking a byte offset, since a run's log is a
// few KB at most (RunSupervisor.swift, Phase 2 slice B) and simplicity here beats micro-saving
// one small re-read per event.
import Foundation
import Darwin

@MainActor
@Observable
final class RunLogTailer {
    private(set) var lines: [String] = []
    private static let maxLines = 200

    private let path: String
    /// `@ObservationIgnored` (pure plumbing, SwiftUI never reads it directly) + `nonisolated
    /// (unsafe)`: deinit runs nonisolated even for a `@MainActor` class, and cancelling a
    /// `DispatchSource` from any thread is itself safe (GCD's own contract) — every write still
    /// happens on the main actor (`watch()`/`init`), so this is a genuine, not a suppressed,
    /// race. Plain `nonisolated` is refused here: the `@Observable` macro cannot apply it to a
    /// mutable TRACKED stored property, hence `@ObservationIgnored` first.
    @ObservationIgnored
    private nonisolated(unsafe) var source: DispatchSourceFileSystemObject?

    init(path: String) {
        self.path = path
        reload()
        watch()
    }

    deinit {
        source?.cancel()
    }

    private func reload() {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines = all.suffix(Self.maxLines).map(String.init)
    }

    private func watch() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}
