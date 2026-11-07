// Kronos v1.2 "harness control" (Phase 2 slice B). `KHarness` was defined by slice A
// (Runs/KronosRunsStore.swift) but left unconsumed; this file is where it is actually read and
// written. A harness is the pinned command line Kronos runs to launch an agent (Settings >
// Agents > Harness, slice B1) — `RunSupervisorEngine` (same directory) reads it back at launch.
//
// The "binary changed" check (B1: "If the binary at a pinned path later differs... the next
// launch refuses") needs a baseline to compare against — what the path resolved to AT PIN TIME.
// `KHarness`'s own fields (fixed by slice A) have no spare column for that, so the resolved
// target is kept as a small device-local fingerprint in `KronosEnv.defaults`, keyed by agent id:
// never synced, never part of the run contract, purely a defensive cache this file owns.

import Foundation
import SwiftData

/// Where a harness's executable resolves against now, compared with where it resolved at pin
/// time: `.unpinned` (no row yet), `.ok` (same binary, or nothing to compare against because this
/// is the pin that just set the fingerprint), `.changed` (the path is gone, or a symlink at that
/// path now points somewhere else — most often a Homebrew upgrade moving the real binary).
public enum HarnessValidation: Equatable, Sendable {
    case unpinned, ok, changed
}

/// Known agent slugs' default binary name and argv template (B1). An unlisted slug's binary name
/// is the slug itself, and its argv is just the prompt — the only thing we can safely assume.
public enum HarnessDefaults {
    public static let searchDirectories = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public static func binaryName(forSlug slug: String) -> String {
        switch slug {
        case "omp", "claude", "codex": return slug
        default: return slug
        }
    }

    public static func defaultArgv(forSlug slug: String) -> [String] {
        switch slug {
        case "omp": return ["-p", "--no-session", "{prompt}"]
        case "claude": return ["-p", "{prompt}"]
        case "codex": return ["exec", "{prompt}"]
        default: return ["{prompt}"]
        }
    }

    /// The CLI flag that carries a chosen model for each known agent slug (handoff-ui slice):
    /// omp and claude both read `--model`; codex reads the shorter `-m`. An unlisted slug gets
    /// the long form, the safer default for an unknown binary's argument parser.
    public static func modelFlag(forSlug slug: String) -> String {
        switch slug {
        case "omp": return "--model"
        case "claude": return "--model"
        case "codex": return "-m"
        default: return "--model"
        }
    }

    /// Searches `directories` (default `searchDirectories`) in order for the slug's known binary
    /// name; the first existing, executable match wins. Nil when none of the folders has it.
    /// `directories` is overridable so a test can point this at a scratch tree instead of
    /// reimplementing the search.
    public static func find(forSlug slug: String, directories: [String] = searchDirectories,
                            fileManager: FileManager = .default) -> String? {
        let name = binaryName(forSlug: slug)
        let home = fileManager.homeDirectoryForCurrentUser.path
        for dir in directories {
            let expanded = dir.hasPrefix("~") ? home + dir.dropFirst(1) : dir
            let candidate = (expanded as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return nil
    }
}

/// `KHarness.argvTemplate` on disk, and the one substitution rule (B2, B5): ONLY an array element
/// that EQUALS the placeholder exactly is replaced — `{prompt}` inside a larger string (e.g.
/// "say {prompt} now") is left untouched.
public enum HarnessArgv {
    private static let placeholder = "{prompt}"

    public static func encode(_ argv: [String]) -> String {
        guard let data = try? JSONEncoder().encode(argv), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    public static func decode(_ raw: String) -> [String] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let argv = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return argv
    }

    /// `model` (when non-blank) is inserted as `[flag, model]` immediately before the prompt,
    /// using `slug`'s own flag (`HarnessDefaults.modelFlag(forSlug:)`) — nil or blank leaves the
    /// composed argv byte-identical to calling this with no model at all (handoff-ui slice: the
    /// "Auto" choice in every model picker means "pass nothing, let the harness pick").
    public static func substituting(_ argv: [String], prompt: String, model: String? = nil, slug: String = "") -> [String] {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        result.reserveCapacity(argv.count + (trimmedModel?.isEmpty == false ? 2 : 0))
        for element in argv {
            guard element == placeholder else { result.append(element); continue }
            if let trimmedModel, !trimmedModel.isEmpty {
                result.append(HarnessDefaults.modelFlag(forSlug: slug))
                result.append(trimmedModel)
            }
            result.append(prompt)
        }
        return result
    }
}

@MainActor
public final class HarnessStore {
    private let context: ModelContext
    private var retainedContainer: ModelContainer?

    public init(context: ModelContext) {
        self.context = context
    }

    /// A store over the runs store in `directory` (the real one in the app) — same convenience
    /// pattern as `RunStore.init(directory:store:hub:)`.
    public convenience init(directory: URL) throws {
        let container = try KronosRunsStore.makeContainer(directory: directory)
        self.init(context: ModelContext(container))
        retainedContainer = container
    }

    public func harness(agentID: UUID) -> KHarness? {
        var d = FetchDescriptor<KHarness>(predicate: #Predicate<KHarness> { $0.agentID == agentID })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Creates or replaces the pinned harness for `agentID` and records its resolved-target
    /// fingerprint (B1: "Saving pins the path and argv").
    @discardableResult
    public func pin(agentID: UUID, executablePath: String, argvTemplate: [String],
                    workingDirectory: String = "", maxMinutes: Int = 120, now: Date = Date(),
                    fileManager: FileManager = .default) -> KHarness {
        let existing = harness(agentID: agentID)
        let h = existing ?? KHarness()
        if existing == nil { context.insert(h) }
        h.agentID = agentID
        h.executablePath = executablePath
        h.argvTemplate = HarnessArgv.encode(argvTemplate)
        h.workingDirectory = workingDirectory
        h.maxMinutes = maxMinutes
        h.pinnedAt = now
        try? context.save()
        Self.storeFingerprint(agentID: agentID, path: executablePath, fileManager: fileManager)
        return h
    }

    public func validate(agentID: UUID, fileManager: FileManager = .default) -> HarnessValidation {
        guard let h = harness(agentID: agentID), !h.executablePath.isEmpty else { return .unpinned }
        guard fileManager.fileExists(atPath: h.executablePath) else { return .changed }
        guard let recorded = Self.fingerprint(agentID: agentID) else { return .ok }
        return Self.resolvedTarget(h.executablePath, fileManager: fileManager) == recorded ? .ok : .changed
    }

    static func resolvedTarget(_ path: String, fileManager: FileManager) -> String {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) ?? path
    }

    private static func fingerprintKey(_ agentID: UUID) -> String { "kronos.harness.resolved.\(agentID.uuidString)" }

    static func fingerprint(agentID: UUID) -> String? {
        KronosEnv.defaults.string(forKey: fingerprintKey(agentID))
    }

    static func storeFingerprint(agentID: UUID, path: String, fileManager: FileManager) {
        KronosEnv.defaults.set(resolvedTarget(path, fileManager: fileManager), forKey: fingerprintKey(agentID))
    }
}
