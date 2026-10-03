import Testing
import Foundation
@testable import KronosCore

/// Hostile-input behaviour of the loopback HTTP framing. Every expectation is a hand-written
/// status code, never derived from the parser.
struct MCPHTTPParserTests {
    private func raw(_ s: String) -> Data { Data(s.utf8) }
    private func post(_ headers: [String], body: String = "") -> Data {
        raw("POST /mcp HTTP/1.1\r\n" + headers.map { $0 + "\r\n" }.joined() + "\r\n" + body)
    }
    private func status(_ d: Data) -> Int? {
        if case .reject(let s) = MCPHTTPParser.parseHead(d) { return s }
        return nil
    }

    @Test func validRequestParsesAndYieldsItsBody() throws {
        let data = post(["Host: 127.0.0.1", "Authorization: Bearer abc", "Content-Length: 5"], body: "hello")
        guard case .head(let head) = MCPHTTPParser.parseHead(data) else { Issue.record("not a head"); return }
        #expect(head.method == "POST")
        #expect(head.path == "/mcp")
        #expect(head.contentLength == 5)
        #expect(head.headers["authorization"] == "Bearer abc")
        #expect(MCPHTTPParser.body(in: data, head: head) == Data("hello".utf8))
    }

    @Test func bodyIsNilUntilEveryPromisedByteArrives() {
        let data = post(["Content-Length: 10"], body: "short")
        guard case .head(let head) = MCPHTTPParser.parseHead(data) else { Issue.record("not a head"); return }
        #expect(MCPHTTPParser.body(in: data, head: head) == nil)
    }

    @Test func extraBytesBeyondContentLengthAreIgnored() {
        let data = post(["Content-Length: 2"], body: "okEXTRA")
        guard case .head(let head) = MCPHTTPParser.parseHead(data) else { Issue.record("not a head"); return }
        #expect(MCPHTTPParser.body(in: data, head: head) == Data("ok".utf8))
    }

    @Test func missingContentLengthMeansEmptyBody() {
        guard case .head(let head) = MCPHTTPParser.parseHead(post(["Host: x"])) else { Issue.record("not a head"); return }
        #expect(head.contentLength == 0)
    }

    @Test func negativeContentLengthIsRejectedNotTrapped() {
        #expect(status(post(["Content-Length: -5"], body: "hello")) == 400)
        #expect(status(post(["Content-Length: -1"])) == 400)
        #expect(status(post(["Content-Length: -0"])) == 400)
    }

    @Test func garbageContentLengthIsRejected() {
        for bad in ["abc", "", "5 5", "5,5", "0x10", "1.5", "+5", " ", "５"] {
            #expect(status(post(["Content-Length: \(bad)"])) == 400, "value \(bad)")
        }
    }

    @Test func hugeContentLengthIsTooLarge() {
        #expect(status(post(["Content-Length: 1048577"])) == 413)
        #expect(status(post(["Content-Length: 99999999999999999999999999"])) == 413)
        #expect(status(post(["Content-Length: 9223372036854775808"])) == 413)
        #expect(status(post(["Content-Length: 4294967296"])) == 413)
    }

    @Test func contentLengthAtTheCapIsAccepted() {
        guard case .head(let head) = MCPHTTPParser.parseHead(post(["Content-Length: 1048576"])) else {
            Issue.record("cap value refused"); return
        }
        #expect(head.contentLength == 1_048_576)
        guard case .head(let zeros) = MCPHTTPParser.parseHead(post(["Content-Length: 0000000005"])) else {
            Issue.record("leading zeros refused"); return
        }
        #expect(zeros.contentLength == 5)
    }

    @Test func duplicateOrConflictingLengthsAreRejected() {
        #expect(status(post(["Content-Length: 5", "Content-Length: 5"])) == 400)
        #expect(status(post(["Content-Length: 5", "content-length: 6"])) == 400)
        #expect(status(post(["Content-Length: 5", "Transfer-Encoding: chunked"])) == 400)
        #expect(status(post(["Transfer-Encoding: chunked"])) == 411)
        #expect(status(post(["Authorization: Bearer a", "Authorization: Bearer b"])) == 400)
    }

    @Test func headerFloodIsRejected() {
        let many = (0..<200).map { "X-Flood-\($0): v" }
        #expect(status(post(many)) == 413)
        let oneHuge = "X-Big: " + String(repeating: "a", count: 40_000)
        #expect(status(post([oneHuge])) == 413)
    }

    @Test func unterminatedHeaderBlockWaitsThenGivesUp() {
        #expect(MCPHTTPParser.parseHead(raw("POST /mcp HTTP/1.1\r\nHost: x\r\n")) == .needMoreHeader)
        #expect(MCPHTTPParser.parseHead(Data()) == .needMoreHeader)
        let endless = raw("POST /mcp HTTP/1.1\r\n" + String(repeating: "A", count: 20_000))
        #expect(MCPHTTPParser.parseHead(endless) == .reject(413))
    }

    @Test func malformedHeadsAreBadRequests() {
        #expect(status(raw("\r\n\r\n")) == 400)
        #expect(status(raw("POST\r\n\r\n")) == 400)
        #expect(status(raw("POST /mcp\r\n\r\n")) == 400)
        #expect(status(raw("POST /mcp HTTP/9\r\n\r\n")) == 400)
        #expect(status(raw("POST mcp HTTP/1.1\r\n\r\n")) == 400)
        #expect(status(raw("POST /mcp HTTP/1.1\r\nno colon here\r\n\r\n")) == 400)
        #expect(status(raw("POST /mcp HTTP/1.1\r\n folded: x\r\n\r\n")) == 400)
        #expect(status(raw("POST /mcp HTTP/1.1\r\nBad Name: x\r\n\r\n")) == 400)
        #expect(status(raw("POST /mcp HTTP/1.1\r\n: empty\r\n\r\n")) == 400)
        #expect(status(raw("POST /mcp HTTP/1.1\nHost: x\n\r\n\r\n")) == 400)
        #expect(status(raw("POST /mcp HTTP/1.1\r\nHost: x\rY\r\n\r\n")) == 400)
    }

    @Test func nonUTF8HeadAndNULAreBadRequests() {
        var d = Data("POST /mcp HTTP/1.1\r\nX-A: ".utf8)
        d.append(contentsOf: [0xFF, 0xFE, 0xC0])
        d.append(Data("\r\n\r\n".utf8))
        #expect(status(d) == 400)
        var n = Data("POST /mcp HTTP/1.1\r\nX-A: a".utf8)
        n.append(0)
        n.append(Data("b\r\n\r\n".utf8))
        #expect(status(n) == 400)
    }

    @Test func authIsDecidableFromTheHeadAloneBeforeAnyBodyByte() {
        // A body was promised but not one byte of it has arrived: the head is still complete,
        // so the transport can answer 401 without reading or decoding the body.
        let data = post(["Content-Length: 1000000", "Authorization: Bearer wrong"])
        guard case .head(let head) = MCPHTTPParser.parseHead(data) else { Issue.record("not a head"); return }
        #expect(MCPHTTPParser.body(in: data, head: head) == nil)
        #expect(BearerAuth.isAuthorized(header: head.headers["authorization"], expectedToken: "secret") == false)
        let none = post(["Content-Length: 4"], body: "{}{}")
        guard case .head(let h2) = MCPHTTPParser.parseHead(none) else { Issue.record("not a head"); return }
        #expect(BearerAuth.isAuthorized(header: h2.headers["authorization"], expectedToken: "secret") == false)
    }

    @Test func wrongTokensTakeTheSameComparisonPathAsTheRightOne() {
        let secret = "k3Yq-Xv9Lm2Rt8"
        // Right token accepted; every wrong shape (first-byte miss, last-byte miss, prefix,
        // longer, empty, wrong scheme, different case of scheme) rejected.
        #expect(BearerAuth.isAuthorized(header: "Bearer \(secret)", expectedToken: secret))
        for bad in ["Bearer X3Yq-Xv9Lm2Rt8", "Bearer k3Yq-Xv9Lm2RtX", "Bearer k3Yq-Xv9Lm2Rt", "Bearer k3Yq-Xv9Lm2Rt8x",
                    "Bearer ", "Bearer", "Basic \(secret)", "bearer \(secret)", secret, ""] {
            #expect(BearerAuth.isAuthorized(header: bad, expectedToken: secret) == false, "header \(bad)")
        }
        #expect(BearerAuth.isAuthorized(header: nil, expectedToken: secret) == false)
        #expect(ConstantTime.equals("abc", "abd") == false)
        #expect(ConstantTime.equals("abc", "abc"))
        #expect(ConstantTime.equals("", ""))
    }

    @Test func listenerIsPinnedToLoopback() {
        #expect(MCPHTTP.bindHost == "127.0.0.1")
        #expect(MCPHTTP.maxBodyBytes == 1_048_576)
        #expect(MCPHTTP.maxConnections > 0 && MCPHTTP.maxConnections <= 64)
        #expect(MCPHTTP.readTimeoutSeconds > 0 && MCPHTTP.readTimeoutSeconds <= 60)
    }

    /// Deterministic generator so a failure is reproducible.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    @Test func fuzzNeverTraps() {
        var rng = SplitMix(state: 0xC0FFEE)
        let seeds = [
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer t\r\nContent-Length: 5\r\n\r\nhello",
            "POST /mcp HTTP/1.1\r\nContent-Length: -5\r\n\r\nhello",
            "GET / HTTP/1.0\r\n\r\n",
        ].map { Array($0.utf8) }
        let tokens = ["-", "0", "9", "\r\n", "\r\n\r\n", ":", " ", "Content-Length", "99999999999999999999", "\0", "\n", "\r"]
        var heads = 0, rejects = 0, waits = 0
        for i in 0..<6000 {
            var bytes: [UInt8]
            switch i % 3 {
            case 0:   // pure noise
                bytes = (0..<Int.random(in: 0...300, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            case 1:   // mutated valid request
                bytes = seeds[Int.random(in: 0..<seeds.count, using: &rng)]
                for _ in 0..<Int.random(in: 1...6, using: &rng) where !bytes.isEmpty {
                    let at = Int.random(in: 0..<bytes.count, using: &rng)
                    switch Int.random(in: 0...2, using: &rng) {
                    case 0: bytes[at] = UInt8.random(in: 0...255, using: &rng)
                    case 1: bytes.remove(at: at)
                    default: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: at)
                    }
                }
            default:  // spliced tokens
                bytes = Array("POST /mcp HTTP/1.1\r\n".utf8)
                for _ in 0..<Int.random(in: 1...12, using: &rng) {
                    bytes += Array(tokens[Int.random(in: 0..<tokens.count, using: &rng)].utf8)
                }
            }
            let data = Data(bytes)
            switch MCPHTTPParser.parseHead(data) {
            case .needMoreHeader: waits += 1
            case .reject(let s):
                rejects += 1
                #expect([400, 411, 413].contains(s))
            case .head(let head):
                heads += 1
                #expect(head.contentLength >= 0 && head.contentLength <= MCPHTTP.maxBodyBytes)
                #expect(head.bodyOffset <= data.count)
                if let body = MCPHTTPParser.body(in: data, head: head) { #expect(body.count == head.contentLength) }
            }
        }
        #expect(heads + rejects + waits == 6000)
        #expect(rejects > 0 && waits > 0)
    }
}
