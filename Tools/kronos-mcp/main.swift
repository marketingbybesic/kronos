// kronos-mcp: stdio <-> HTTP bridge between an MCP client (Claude Code, Codex, Hermes, Claude
// Desktop, Cursor) and the Kronos app's loopback MCP server. Lives at
// Kronos.app/Contents/MacOS/kronos-mcp so it always talks to ITS OWN host app (the demo
// bridge only ever opens the demo). Foundation only; does not import KronosCore on purpose:
// the client launches it constantly and it must start in milliseconds.
//
// Wire: newline-delimited JSON-RPC on stdin/stdout (what stdio MCP clients speak). Logs go to
// stderr only, stdout carries protocol and nothing else. The token is never printed.

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let version = "1.0.0"
let disabledMessage = "Kronos: turn on AI access (MCP) in Settings > MCP"

func log(_ s: String) { FileHandle.standardError.write(Data(("kronos-mcp: " + s + "\n").utf8)) }

// MARK: - Host app and secrets (replicates KronosStore.folderName: `*.demo` -> "Kronos Demo")

func hostApp() -> URL? {
    if let o = ProcessInfo.processInfo.environment["KRONOS_APP"], !o.isEmpty { return URL(fileURLWithPath: o) }
    var url = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
    while url.path != "/" {
        if url.pathExtension == "app" { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

func bundleID(_ app: URL) -> String? {
    (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))?["CFBundleIdentifier"] as? String
}

func secretsDir(_ bid: String?) -> URL {
    // KRONOS_STORE_DIR is the app's own override (Runtime.containerDirectory); honour it too.
    if let o = ProcessInfo.processInfo.environment["KRONOS_STORE_DIR"], !o.isEmpty {
        return URL(fileURLWithPath: o).appendingPathComponent("secrets")
    }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let folder = bid?.hasSuffix(".demo") == true ? "Kronos Demo" : "Kronos"
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/\(folder)/secrets")
}

struct Endpoint { let url: URL; let pid: Int32; let port: Int }

let app = hostApp()
let bid = app.flatMap(bundleID)
let secrets = secretsDir(bid)

func readToken() -> String? {
    guard let d = try? Data(contentsOf: secrets.appendingPathComponent("mcp_token")),
          let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty else { return nil }
    return s
}

/// nil when the file is absent or malformed; `alive` says whether its pid still runs.
func readEndpoint() -> (Endpoint, alive: Bool)? {
    guard let d = try? Data(contentsOf: secrets.appendingPathComponent("mcp_endpoint.json")),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let port = j["port"] as? Int, let pid = j["pid"] as? Int,
          let url = URL(string: (j["url"] as? String) ?? "http://127.0.0.1:\(port)/mcp") else { return nil }
    // Only ever talk to loopback, whatever the file says.
    guard let host = url.host, host == "127.0.0.1" || host == "localhost" else { return nil }
    let alive = kill(Int32(pid), 0) == 0
    return (Endpoint(url: url, pid: Int32(pid), port: port), alive)
}

// MARK: - Subcommands

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--version") { print("kronos-mcp \(version)"); exit(0) }
if args.contains("--doctor") {
    print("app: \(app?.path ?? "not found (run the helper from inside Kronos.app)")")
    print("bundle id: \(bid ?? "unknown")")
    print("secrets dir: \(secrets.path)")
    switch readEndpoint() {
    case .some(let (e, alive)): print("endpoint: \(alive ? "running" : "stale") pid=\(e.pid) port=\(e.port)")
    case .none: print("endpoint: absent")
    }
    print("token present: \(readToken() == nil ? "no" : "yes")")
    exit(0)
}

// MARK: - Transport

func write(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let s = String(data: d, encoding: .utf8) else { return }
    print(s)
}

func rpcError(_ id: Any?, _ code: Int, _ msg: String) {
    guard let id else { log(msg); return }   // a notification has nobody to answer
    write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]])
}

func launchHost() {
    guard let app else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", app.path, "--args", "--mcp-background"]
    try? p.run(); p.waitUntilExit()
}

/// Live endpoint, launching the host app in the background when needed. nil = not reachable.
func liveEndpoint(launch: Bool) -> Endpoint? {
    if let (e, alive) = readEndpoint(), alive { return e }
    guard launch else { return nil }
    log("starting Kronos in the background")
    launchHost()
    for _ in 0..<40 {   // 10 s
        usleep(250_000)
        if let (e, alive) = readEndpoint(), alive { return e }
    }
    return nil
}

enum Outcome { case ok(Int, Data, String), refused, timedOut, failed(String) }

func post(_ e: Endpoint, token: String, body: Data, timeout: TimeInterval) -> Outcome {
    var r = URLRequest(url: e.url, timeoutInterval: timeout)
    r.httpMethod = "POST"
    r.httpBody = body
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    let sem = DispatchSemaphore(value: 0)
    var out = Outcome.failed("no response")
    URLSession(configuration: .ephemeral).dataTask(with: r) { data, resp, err in
        if let err = err as? URLError {
            switch err.code {
            case .cannotConnectToHost, .networkConnectionLost: out = .refused
            case .timedOut: out = .timedOut
            default: out = .failed(err.localizedDescription)
            }
        } else if let h = resp as? HTTPURLResponse {
            out = .ok(h.statusCode, data ?? Data(), h.value(forHTTPHeaderField: "Content-Type") ?? "")
        }
        sem.signal()
    }.resume()
    sem.wait()
    return out
}

/// Answers `initialize` locally when the app is unreachable so the client can connect and show
/// the reason on the first real request, instead of a silent "failed to start".
func localInitialize(_ id: Any, _ params: [String: Any]?) {
    write(["jsonrpc": "2.0", "id": id, "result": [
        "protocolVersion": (params?["protocolVersion"] as? String) ?? "2025-03-26",
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "kronos", "version": version]]])
}

func handle(_ line: String) {
    guard let body = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        log("ignored a line that is not a JSON object"); return
    }
    let id = msg["id"]
    let method = msg["method"] as? String
    let isCall = method == "tools/call"
    let timeout: TimeInterval = isCall ? 300 : 30

    var relaunched = false, reauthed = false
    while true {
        // The app writes the token the moment MCP starts, so a missing token after a launch
        // attempt really means MCP is off. Launch first (the endpoint file appears with it).
        guard let e = liveEndpoint(launch: !relaunched) else {
            if method == "initialize", let id { localInitialize(id, msg["params"] as? [String: Any]) }
            else { rpcError(id, -32000, disabledMessage) }
            return
        }
        guard let token = readToken() else {
            if method == "initialize", let id { localInitialize(id, msg["params"] as? [String: Any]) }
            else { rpcError(id, -32000, disabledMessage) }
            return
        }
        switch post(e, token: token, body: body, timeout: timeout) {
        case .ok(let code, let data, let type):
            if code == 401 && !reauthed { reauthed = true; continue }   // token regenerated meanwhile
            if code == 202 { return }
            if code == 200 { emit(data, type); return }
            rpcError(id, -32000, code == 401 ? "Kronos: the access token was rejected, reconnect from Settings > MCP" : "Kronos: HTTP \(code)")
            return
        case .refused:
            // Nothing was sent, so even tools/call is safe to retry once after a relaunch.
            if relaunched { rpcError(id, -32000, disabledMessage); return }
            relaunched = true
            launchHost(); sleep(2)   // stale-but-alive endpoint or app just quit: give it a moment
            continue
        case .timedOut:
            // Never resend: the app may already have executed the call.
            rpcError(id, -32001, "Kronos did not answer in time"); return
        case .failed(let m):
            rpcError(id, -32000, "Kronos: \(m)"); return
        }
    }
}

func emit(_ data: Data, _ type: String) {
    if type.contains("event-stream") {
        for l in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") where l.hasPrefix("data:") {
            print(l.dropFirst(5).trimmingCharacters(in: .whitespaces))
        }
    } else if let o = try? JSONSerialization.jsonObject(with: data) {
        // Re-encode so a pretty-printed body still fits newline-delimited framing.
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .fragmentsAllowed]),
           let s = String(data: d, encoding: .utf8) { print(s) }
    } else {
        log("non-JSON body dropped")
    }
}

// Sequential on purpose (one request at a time; clients that pipeline get ordered
// replies, upgrade to a serial queue per id only if a slow tool call blocks others).
while let line = readLine(strippingNewline: true) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    handle(line)
}
