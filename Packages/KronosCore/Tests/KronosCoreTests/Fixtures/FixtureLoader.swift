import Foundation

/// Loads a recorded provider reply from `Tests/KronosCoreTests/Fixtures/`.
/// Every fixture here is a captured (or, for negative cases, hand-built to
/// match a captured shape) provider response body used by `AIRouterTests`
/// and friends so the test suite never depends on network access.
enum FixtureLoader {
    /// `#filePath` for this file is itself inside `Fixtures/`, so its
    /// directory IS the fixtures directory — no path guessing needed.
    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// Raw bytes of a fixture file (e.g. `"triage_ok.json"`, `"triage_ok.sse"`).
    static func data(_ name: String) throws -> Data {
        let url = fixturesDirectory.appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// The fixture's content decoded as UTF-8 text.
    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}
