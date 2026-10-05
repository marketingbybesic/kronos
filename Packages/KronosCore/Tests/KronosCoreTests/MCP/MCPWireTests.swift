#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// release wire/protocol behaviour: encoding, id precision, version echo, 202s, Origin, endpoint file.
@MainActor
struct MCPWireTests {
    private func dispatcher() throws -> MCPDispatcher {
        MCPDispatcher(store: try TaskStore(inMemory: true), ranking: RankingEngine())
    }
    private func json(_ d: Data?) -> Any? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    private func body(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    private func req(_ o: [String: Any]) -> [String: Any] {
        var r: [String: Any] = ["jsonrpc": "2.0"]; o.forEach { r[$0] = $1 }; return r
    }

    @Test func numbersAndBoolsRoundTrip() throws {
        let raw = Data(#"{"a":0,"b":1,"c":true,"d":false,"e":2,"f":1.5}"#.utf8)
        let parsed = try JSONSerialization.jsonObject(with: raw)
        let out = try JSONEncoder().encode(AnyEncodable(parsed))
        let d = try JSONSerialization.jsonObject(with: out) as! [String: Any]
        for (k, isBool) in [("a", false), ("b", false), ("c", true), ("d", true), ("e", false)] {
            #expect((CFGetTypeID(d[k] as! NSNumber) == CFBooleanGetTypeID()) == isBool, "\(k)")
        }
        #expect((d["b"] as! NSNumber).intValue == 1)
        #expect((d["c"] as! NSNumber).boolValue == true)
        #expect((d["f"] as! NSNumber).doubleValue == 1.5)
        // native Swift values too
        let native = try JSONEncoder().encode(AnyEncodable(["t": true, "one": 1] as [String: Any]))
        let n = try JSONSerialization.jsonObject(with: native) as! [String: Any]
        #expect(CFGetTypeID(n["t"] as! NSNumber) == CFBooleanGetTypeID())
        #expect(CFGetTypeID(n["one"] as! NSNumber) != CFBooleanGetTypeID())
    }

    @Test func idKeepsIntPrecisionAndRejectsBool() throws {
        let big = try MCPRequest.parse(body(req(["id": 9007199254740993, "method": "ping"])))
        #expect(big.id == .number(9007199254740993))
        let str = try MCPRequest.parse(body(req(["id": "abc", "method": "ping"])))
        #expect(str.id == .string("abc"))
        #expect(throws: MCPTransportError.self) { try MCPRequest.parse(self.body(self.req(["id": true, "method": "ping"]))) }
        #expect(throws: MCPTransportError.self) { try MCPRequest.parse(self.body(self.req(["id": 1.5, "method": "ping"]))) }
    }

    @Test func jsonrpcMustBe2_0() {
        #expect(throws: MCPTransportError.self) { try MCPRequest.parse(self.body(["id": 1, "method": "ping"])) }
        #expect(throws: MCPTransportError.self) { try MCPRequest.parse(self.body(["jsonrpc": "1.0", "id": 1, "method": "ping"])) }
    }

    @Test func initializeEchoesSupportedVersionElseNewest() throws {
        let d = try dispatcher()
        func version(_ asked: String?) -> String? {
            var p: [String: Any] = [:]; if let asked { p["protocolVersion"] = asked }
            let r = d.handleBody(body(req(["id": 1, "method": "initialize", "params": p])))
            return ((json(r.body) as? [String: Any])?["result"] as? [String: Any])?["protocolVersion"] as? String
        }
        #expect(version("2024-11-05") == "2024-11-05")
        #expect(version("2025-03-26") == "2025-03-26")
        #expect(version("2025-06-18") == "2025-06-18")
        #expect(version("2099-01-01") == "2025-06-18")
        #expect(version(nil) == "2025-06-18")
    }

    @Test func notificationsAndClientResponsesGet202() throws {
        let d = try dispatcher()
        for o in [req(["method": "notifications/initialized"]),
                  req(["method": "notifications/cancelled", "params": ["requestId": 1]]),
                  req(["id": 5, "result": [String: Any]()])] {
            let r = d.handleBody(body(o))
            #expect(r.status == 202); #expect(r.body == nil)
        }
        #expect(d.handleBody(body(req(["id": 1, "method": "ping"]))).status == 200)
    }

    @Test func unknownToolIs32602AndUnknownMethodStill32601() throws {
        let d = try dispatcher()
        func code(_ o: [String: Any]) -> Int? {
            ((json(d.handleBody(body(o)).body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int
        }
        #expect(code(req(["id": 1, "method": "tools/call", "params": ["name": "nope"]])) == -32602)
        #expect(code(req(["id": 2, "method": "bogus/method"])) == -32601)
    }

    @Test func batchReturnsArrayAndEmptyIsRejected() throws {
        let d = try dispatcher()
        let batch = try JSONSerialization.data(withJSONObject: [
            req(["id": 1, "method": "ping"]), req(["method": "notifications/initialized"]), req(["id": 2, "method": "ping"])])
        let r = d.handleBody(batch)
        #expect((json(r.body) as? [[String: Any]])?.count == 2)
        let empty = d.handleBody(Data("[]".utf8))
        #expect(((json(empty.body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test func onlyMutatingToolsReportMutation() throws {
        let d = try dispatcher()
        func mutated(_ tool: String, _ args: [String: Any] = [:]) -> Bool {
            d.handleBody(body(req(["id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args]]))).mutated
        }
        #expect(!mutated("list_tasks")); #expect(!mutated("ordo_get")); #expect(!mutated("rules_list"))
        #expect(!mutated("get_task", ["id": "x"]))
        #expect(mutated("create_task", ["title": "t"]))
        #expect(!d.handleBody(body(req(["id": 1, "method": "ping"]))).mutated)
    }

    @Test func originDecisions() {
        #expect(MCPEndpointFile.isOriginAllowed(nil))
        for o in ["null", "http://127.0.0.1", "http://127.0.0.1:47311", "http://localhost", "http://localhost:3000"] {
            #expect(MCPEndpointFile.isOriginAllowed(o), "\(o)")
        }
        for o in ["https://evil.example", "http://127.0.0.1.evil.example", "http://localhost:abc",
                  "http://localhost.evil.com:80", "https://127.0.0.1", ""] {
            #expect(!MCPEndpointFile.isOriginAllowed(o), "\(o)")
        }
    }

    @Test func endpointFileIs0600AndRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-ep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try MCPEndpointFile.write(port: 47312, pid: 99, bundleID: "com.besic.kronos.demo", directory: dir)
        let url = dir.appendingPathComponent("mcp_endpoint.json")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
        #expect(perms == 0o600)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(obj["port"] as? Int == 47312); #expect(obj["pid"] as? Int == 99)
        #expect(obj["bundleId"] as? String == "com.besic.kronos.demo")
        #expect(obj["url"] as? String == "http://127.0.0.1:47312/mcp")
        #expect(obj["token"] == nil)
        MCPEndpointFile.remove(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func legacyDiscoveryIsDeleted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let f = home.appendingPathComponent(".kronos-mcp.json")
        try Data("{}".utf8).write(to: f)
        MCPEndpointFile.removeLegacy(home: home)
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }
}

#endif
