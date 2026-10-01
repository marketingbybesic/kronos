// Kronos/Settings/UpdateCheck.swift
// "Check for updates" without a developer id: one GET to the public GitHub releases API,
// compare the latest tag with this build's marketing version, show the result. No self-update
// and no background polling: it only ever runs from the About tab's button. Foundation only, so
// scripts/updatecheck-selftest.swift compiles this real file.
import Foundation

enum UpdateOutcome: Equatable {
    case upToDate
    case available(version: String, page: URL)
    /// The repository has no published release yet (HTTP 404): not an error, nothing to install.
    case noRelease
    case failed
}

enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/marketingbybesic/kronos/releases/latest")!
    static let timeout: TimeInterval = 10

    struct Release: Equatable {
        let tag: String
        let page: URL
    }

    /// `tag_name` + `html_url` from the API body. The page URL is opened in the browser, so only
    /// an https github.com address is accepted: a reply that points somewhere else is rejected.
    static func parseRelease(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty,
              let html = object["html_url"] as? String, let url = URL(string: html),
              url.scheme == "https", let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else { return nil }
        return Release(tag: tag, page: url)
    }

    /// "v1.2.0-beta.3+7" -> [1, 2, 0]. Nil when no numeric core can be read.
    static func core(of version: String) -> [Int]? {
        var s = version.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// "v1.2.0-beta.3" -> "1.2.0-beta.3": what a person reads.
    static func display(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Newer only when the numeric core is higher. The installed marketing version carries no
    /// pre-release marker ("1.0.0" is Beta 1), so the same core is "up to date" even when the
    /// tag is "1.0.0-beta.2": claiming an update there would be a guess, not a fact.
    static func isNewer(tag: String, than current: String) -> Bool {
        guard var a = core(of: tag), var b = core(of: current) else { return false }
        while a.count < b.count { a.append(0) }
        while b.count < a.count { b.append(0) }
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }

    static func outcome(for release: Release, current: String) -> UpdateOutcome {
        isNewer(tag: release.tag, than: current)
            ? .available(version: display(release.tag), page: release.page) : .upToDate
    }

    /// Maps one HTTP answer to an outcome.
    static func outcome(status: Int, body: Data, current: String) -> UpdateOutcome {
        switch status {
        case 200:
            guard let release = parseRelease(body) else { return .failed }
            return outcome(for: release, current: current)
        case 404: return .noRelease
        default: return .failed
        }
    }

    /// The network call: no auth, 10 s timeout, never throws.
    static func fetch(current: String, session: URLSession = .shared) async -> UpdateOutcome {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kronos-update-check", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            return outcome(status: http.statusCode, body: data, current: current)
        } catch {
            return .failed
        }
    }
}
