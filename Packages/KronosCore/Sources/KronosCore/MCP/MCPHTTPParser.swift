#if os(macOS)
// MCP transport framing. Pure, total parsing of the HTTP/1.1 request head that
// arrives on the loopback socket. Everything here treats the bytes as hostile:
// no force-unwraps, no range slicing with computed offsets, no arithmetic that
// can overflow. A malformed head becomes a status code, never a trap.

import Foundation

public enum MCPHTTP {
    /// The only address the listener may bind.
    public static let bindHost = "127.0.0.1"
    public static let maxBodyBytes = 1_048_576
    public static let maxHeaderBytes = 16 * 1024
    public static let maxHeaderLines = 64
    public static let maxConnections = 32
    /// Wall-clock budget for one request to arrive in full.
    public static let readTimeoutSeconds = 15
}

public struct MCPHTTPHead: Equatable, Sendable {
    public let method: String
    public let path: String
    /// Lower-cased header names.
    public let headers: [String: String]
    /// Offset of the first body byte in the buffer the head was parsed from.
    public let bodyOffset: Int
    public let contentLength: Int
}

public enum MCPHTTPParse: Equatable, Sendable {
    /// The blank line ending the header block has not arrived yet.
    case needMoreHeader
    /// Answer with this status and close the connection.
    case reject(Int)
    case head(MCPHTTPHead)
}

public enum MCPHTTPParser {
    /// Headers that must appear at most once; a repeat is a smuggling signal.
    private static let singletons: Set<String> = [
        "content-length", "authorization", "transfer-encoding", "origin", "host", "content-type",
    ]

    public static func parseHead(_ data: Data) -> MCPHTTPParse {
        let window = Array(data.prefix(MCPHTTP.maxHeaderBytes + 4))
        guard let terminator = findTerminator(window) else {
            return window.count >= MCPHTTP.maxHeaderBytes + 4 ? .reject(413) : .needMoreHeader
        }
        let headerBytes = Array(window.prefix(terminator))
        guard let lines = splitLines(headerBytes) else { return .reject(400) }
        if lines.count > MCPHTTP.maxHeaderLines { return .reject(413) }
        guard let first = lines.first, let requestLine = String(bytes: first, encoding: .utf8) else {
            return .reject(400)
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              !parts[0].isEmpty, parts[1].hasPrefix("/") else { return .reject(400) }

        var headers: [String: String] = [:]
        for raw in lines.dropFirst() {
            guard let line = String(bytes: raw, encoding: .utf8),
                  let colon = line.firstIndex(of: ":"),
                  let firstChar = line.first, firstChar != " ", firstChar != "\t" else { return .reject(400) }
            let name = String(line[..<colon])
            guard isToken(name) else { return .reject(400) }
            let key = name.lowercased()
            if singletons.contains(key), headers[key] != nil { return .reject(400) }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        if headers["transfer-encoding"] != nil {
            return .reject(headers["content-length"] != nil ? 400 : 411)
        }
        var length = 0
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return .reject(400) }
            let digits = value.drop(while: { $0 == "0" })
            if digits.count > 9 { return .reject(413) }
            length = Int(digits) ?? 0
            if length > MCPHTTP.maxBodyBytes { return .reject(413) }
        }
        return .head(MCPHTTPHead(method: String(parts[0]), path: String(parts[1]), headers: headers,
                                 bodyOffset: terminator + 4, contentLength: length))
    }

    /// The body once every byte the head promised has arrived; nil while still incomplete.
    public static func body(in data: Data, head: MCPHTTPHead) -> Data? {
        guard data.count >= head.bodyOffset + head.contentLength else { return nil }
        return Data(data.dropFirst(head.bodyOffset).prefix(head.contentLength))
    }

    private static func findTerminator(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
            return i
        }
        return nil
    }

    /// Splits on CRLF. A NUL, a bare CR or a bare LF means the head is malformed.
    private static func splitLines(_ bytes: [UInt8]) -> [[UInt8]]? {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0 || b == 0x0A { return nil }
            if b == 0x0D {
                guard i + 1 < bytes.count, bytes[i + 1] == 0x0A else { return nil }
                lines.append(current)
                current = []
                i += 2
                continue
            }
            current.append(b)
            i += 1
        }
        lines.append(current)
        return lines
    }

    private static func isToken(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || "!#$%&'*+-.^_`|~".utf8.contains(c)
        }
    }
}
#endif
