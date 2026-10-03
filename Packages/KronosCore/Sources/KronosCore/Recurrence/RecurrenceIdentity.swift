// Deterministic ids for recurring instances.
//
// Two devices (or the app and its background MCP process) that complete the same instance each
// spawn "the next one". With random ids that was two next instances. The next instance's id is
// now derived from the series and its due day, so both sides produce the SAME id: the spawner
// finds the row the other side already made, and a sync merge collapses the two copies in the
// dedupe sweep (same id -> one row).

import CryptoKit
import Foundation

/// Name-based UUIDs, version 5 (RFC 4122 §4.3: SHA-1 of namespace bytes + name bytes).
public enum KUUID {
    public static func v5(namespace: UUID, name: String) -> UUID {
        var input = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        input.append(contentsOf: Array(name.utf8))
        var b = Array(Insecure.SHA1.hash(data: input).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // version 5
        b[8] = (b[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

public enum RecurrenceIdentity {
    /// The id of the series instance due on `dueDay` (a `Day` number): UUIDv5(seriesID, "<day>").
    public static func instanceID(seriesID: UUID, dueDay: Int) -> UUID {
        KUUID.v5(namespace: seriesID, name: String(dueDay))
    }

    /// The id of the fresh copy of step `stepID` that the instance `instanceID` gets.
    public static func stepCopyID(instanceID: UUID, stepID: UUID) -> UUID {
        KUUID.v5(namespace: instanceID, name: "step:" + stepID.uuidString)
    }
}
