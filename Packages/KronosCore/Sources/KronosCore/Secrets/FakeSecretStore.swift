// KronosCore/Secrets. In-memory `SecretStoring` for tests: never calls a Security framework
// function, so a test using this can never make macOS show a Keychain dialog. Counts every
// call per name so a test can assert "zero reads happened before X" and "exactly one read
// happened after Y" instead of trusting that a lazy path stayed lazy.
import Foundation

public final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var readCounts: [String: Int] = [:]

    public init(seed: [String: String] = [:]) {
        values = seed
    }

    public func read(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        readCounts[name, default: 0] += 1
        return values[name]
    }

    public func write(_ value: String, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[name] = value
    }

    public func delete(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: name)
    }

    public func hasValue(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[name] != nil
    }

    /// How many times `read(name)` has been called. A launch-path test asserts this is 0
    /// before any request/AI-call happens, and exactly 1 after the first one.
    public func readCount(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return readCounts[name, default: 0]
    }

    public func totalReadCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return readCounts.values.reduce(0, +)
    }
}
