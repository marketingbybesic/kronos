// Kronos/Detail/InspectorRunSection.swift
// Above Details when the task has any run (Kronos v1.2 Phase 2 slice C2): the latest run's
// state, its note, its artifacts, a live log tail for a Kronos-launched run, and the Stop /
// Open log / Run again controls. Sibling to InspectorReviewSection — same "no header, the
// content IS the heading" shape, same chip/button vocabulary as LinksSection/KChip.
import SwiftUI
import AppKit
import KronosCore

struct InspectorRunSection: View {
    let model: AppModel
    let task: KTask

    var body: some View {
        let _ = model.version
        if let run = model.runs?.runs(taskID: task.id).first {
            content(run)
                .id(run.id)
        }
    }

    @ViewBuilder
    private func content(_ run: KAgentRun) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            headline(run)
            if run.progress >= 0 {
                ProgressView(value: run.progress)
                    .progressViewStyle(.linear)
                    .tint(Tok.textSecondary)
                    .accessibilityLabel(String(format: String(localized: "inspector.run.progress"), Int((run.progress * 100).rounded())))
                    .uiTestAnchor("inspector.run.progress")
            }
            if !run.note.isEmpty {
                Text(run.note)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .uiTestAnchor("inspector.run.note")
            }
            let artifacts = Self.decodeArtifacts(run.artifactsJSON)
            if !artifacts.isEmpty {
                VStack(alignment: .leading, spacing: Space.x1) {
                    ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                        RunArtifactChip(artifact: artifact)
                    }
                }
            }
            if run.launchedByKronos, !run.logPath.isEmpty {
                InspectorRunLogView(logPath: run.logPath)
            }
            buttons(run)
        }
        .padding(.vertical, Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uiTestAnchor("inspector.run")
    }

    private func headline(_ run: KAgentRun) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
            Text(String(format: String(localized: "inspector.run.headline"), RunAgentNaming.displayName(forSlug: run.agentSlug), stateWord(run.stateRaw)))
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
            Spacer(minLength: Space.x2)
            Text(timeText(run))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
        }
        .uiTestAnchor("inspector.run.headline")
    }

    private func stateWord(_ raw: String) -> String {
        switch raw {
        case "running": return String(localized: "inspector.run.state.running")
        case "done": return String(localized: "inspector.run.state.done")
        case "failed": return String(localized: "inspector.run.state.failed")
        case "stopped": return String(localized: "inspector.run.state.stopped")
        case "expired": return String(localized: "inspector.run.state.expired")
        case "handoff": return String(localized: "inspector.run.state.handoff")
        default: return raw
        }
    }

    private func timeText(_ run: KAgentRun) -> String {
        if run.stateRaw == "running" {
            let elapsed = Self.durationFormatter.string(from: run.startedAt, to: Date()) ?? ""
            return String(format: String(localized: "inspector.run.elapsed"), elapsed)
        }
        return String(format: String(localized: "inspector.run.ended"), relative(run.endedAt ?? run.startedAt))
    }

    @ViewBuilder
    private func buttons(_ run: KAgentRun) -> some View {
        let showStop = run.stateRaw == "running"
        let showLog = !run.logPath.isEmpty
        let showOpenTerminal = run.launchedByKronos && !run.logPath.isEmpty
        let showRunAgain = run.stateRaw != "running"
        if showStop || showLog || showRunAgain {
            HStack(spacing: Space.x2) {
                if showStop {
                    Button(String(localized: "inspector.run.stop")) {
                        LiveRuns.stop(runID: run.id)
                        model.didMutate()
                    }
                    .kButton(.secondary, size: .compact)
                    .uiTestAnchor("inspector.run.stop")
                }
                if showLog {
                    Button(String(localized: "inspector.run.openlog")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: run.logPath))
                    }
                    .kButton(.ghost, size: .compact)
                    .uiTestAnchor("inspector.run.openlog")
                }
                if showOpenTerminal {
                    Button(String(localized: "inspector.run.openterminal")) {
                        openInTerminal(run)
                    }
                    .kButton(.ghost, size: .compact)
                    .uiTestAnchor("inspector.run.openterminal")
                }
                if showRunAgain {
                    Button(String(localized: "inspector.run.runagain")) {
                        runAgain(run)
                    }
                    .kButton(.secondary, size: .compact)
                    .uiTestAnchor("inspector.run.runagain")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func runAgain(_ run: KAgentRun) {
        switch model.runLauncher.canLaunch(agentID: run.agentID) {
        case .unavailable(let reason):
            UndoToastCenter.shared.showNotice(reason)
        case .available:
            try? model.runLauncher.launch(taskID: run.taskID, agentID: run.agentID,
                                          model: HandoffModelPrefs.lastUsed(agentID: run.agentID))
        }
    }

    /// A tiny 0700 `.command` file under the Runs directory (the same directory `run.logPath`
    /// already lives in) that tails the run's log — opening it is exactly what Finder's own
    /// "Open" does for a `.command` file, so this is the simplest robust way to hand a live log
    /// follow to whatever the user's default terminal app is (handoff-ui slice). Written once
    /// per run: a repeat click on the same run reuses the file already there rather than
    /// rewriting it, so a terminal window already following it keeps following the same file.
    private func openInTerminal(_ run: KAgentRun) {
        guard run.launchedByKronos, !run.logPath.isEmpty else { return }
        let logURL = URL(fileURLWithPath: run.logPath)
        let commandURL = logURL.deletingLastPathComponent().appendingPathComponent("\(run.id.uuidString).command")
        if !FileManager.default.fileExists(atPath: commandURL.path) {
            let escapedLogPath = run.logPath.replacingOccurrences(of: "'", with: "'\\''")
            let script = "#!/bin/zsh\nexec tail -n 200 -f '\(escapedLogPath)'\n"
            FileManager.default.createFile(atPath: commandURL.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700])
        }
        NSWorkspace.shared.open(commandURL)
    }

    /// `RunArtifact.decodeList` (RunStore.swift) is KronosCore-internal; this app-target view
    /// decodes the same JSON shape directly through `RunArtifact`'s own PUBLIC `Codable`
    /// conformance instead (no KronosCore edit needed — out of this slice's owned paths).
    private static func decodeArtifacts(_ json: String) -> [RunArtifact] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RunArtifact].self, from: data)) ?? []
    }

    private func relative(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.dateTimeStyle = .named
        return f
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropLeading
        return f
    }()
}

/// One artifact chip: file reveals in Finder, diff opens the file, commit/pr/url open their
/// ref as a URL when it parses as one (otherwise the chip still shows, just does nothing on
/// tap — never silently claims to open something it cannot).
private struct RunArtifactChip: View {
    let artifact: RunArtifact

    var body: some View {
        KChip(artifact.title?.isEmpty == false ? artifact.title! : artifact.ref, onTap: open) {
            Icon(iconName, size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
        }
        .help(artifact.ref)
        .uiTestAnchor("inspector.run.artifact." + artifact.kind)
    }

    private var iconName: String {
        switch artifact.kind {
        case "file": return "file"
        case "diff": return "file-diff"
        case "commit": return "git-commit"
        case "pr": return "git-pull-request"
        default: return "link"   // "url" and any future kind
        }
    }

    private func open() {
        switch artifact.kind {
        case "file":
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.ref)])
        case "diff":
            NSWorkspace.shared.open(URL(fileURLWithPath: artifact.ref))
        default:   // commit, pr, url — any scheme (http/https, and custom schemes like
            // obsidian:// or notion://, the same breadth ContextLinkActions.open allows for
            // a `.web` ContextLink) opens via NSWorkspace; a malformed or schemeless ref does
            // nothing rather than claiming to open something it cannot.
            guard let url = URL(string: artifact.ref), let scheme = url.scheme, !scheme.isEmpty else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

/// The live log tail (last 200 lines, monospaced, auto-following, collapsible) — shown only
/// for a Kronos-launched run, read by tailing `logPath` with a DispatchSource file monitor
/// (RunLogTailer.swift).
private struct InspectorRunLogView: View {
    let logPath: String
    @State private var isExpanded = false
    @State private var tailer: RunLogTailer?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Button {
                withAnimation(Motion.curve(Motion.fast)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Space.x1) {
                    Icon("chevron-right", size: Metrics.iconXS)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(String(localized: isExpanded ? "inspector.run.log.hide" : "inspector.run.log.show"))
                }
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .frame(height: Metrics.minHit, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .uiTestAnchor("inspector.run.log.toggle")
            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array((tailer?.lines ?? []).enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(Typo.mono)
                                    .foregroundStyle(Tok.textSecondary)
                                    .id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .background(Tok.overlay)
                    .onChange(of: tailer?.lines.count) { _, _ in
                        guard let last = tailer?.lines.indices.last else { return }
                        withAnimation(Motion.curve(Motion.fast)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .uiTestAnchor("inspector.run.log")
                .onAppear { if tailer == nil { tailer = RunLogTailer(path: logPath) } }
            }
        }
    }
}
