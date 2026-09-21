// MCP. Constant-time bearer token comparison. A `==` on String/Data short-circuits on the
// first mismatched byte, which leaks the token's length and prefix through a
// timing side channel to anything that can measure response latency —
// unlikely over loopback, but the spec asks for it explicitly and it costs
// nothing to do right.

import Foundation

public enum ConstantTime {
    /// True only when `a` and `b` hold the identical bytes. Always walks the
    /// full length of the longer input and never returns early on a
    /// mismatch, so the running time does not depend on WHERE the two values
    /// first differ — only on their lengths, which are not secret.
    public static func equals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff: UInt8 = a.count == b.count ? 0 : 1
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }

    public static func equals(_ a: Data, _ b: Data) -> Bool {
        equals([UInt8](a), [UInt8](b))
    }

    public static func equals(_ a: String, _ b: String) -> Bool {
        equals(Array(a.utf8), Array(b.utf8))
    }
}
