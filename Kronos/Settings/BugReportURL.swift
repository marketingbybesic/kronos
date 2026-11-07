// Kronos/Settings/BugReportURL.swift
// Builds the "new issue" URL used by Settings > About and the Help menu's "Report a bug" item.
// No telemetry and no new network code: the whole feature is one URL handed to
// NSWorkspace.shared.open; GitHub Issues (the public repo) is the only collection point.

import Foundation

enum BugReportURL {
    /// github.com/marketingbybesic/kronos/issues/new with a prefilled, URL-encoded body: app
    /// version/build (Bundle) and macOS version (ProcessInfo), plus blank Steps/Expected/Actual
    /// sections for the reporter to fill in. English only: GitHub itself is English.
    static func make() -> URL {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["KronosBuildID"] as? String ?? "dev"
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
        **Kronos version:** \(version) (build \(build))
        **macOS:** \(macOS)

        **Steps to reproduce**


        **Expected**


        **Actual**

        """
        var components = URLComponents(string: "https://github.com/marketingbybesic/kronos/issues/new")!
        let bodyParam = "body" // query item key, not user-facing text
        components.queryItems = [URLQueryItem(name: bodyParam, value: body)]
        return components.url!
    }
}
