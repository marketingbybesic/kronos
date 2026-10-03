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

/// `Claude Code` becomes `claude-code`: the file name an agent's token lives under.
func agentSlug(_ raw: String) -> String? {
    var out = ""
    for ch in raw.lowercased() {
        if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") { out.append(ch) }
        else if !out.isEmpty, out.last != "-" { out.append("-") }
    }
    out = String(out.prefix(32))
    while out.last == "-" { out.removeLast() }
    return out.isEmpty ? nil : out
}

func readTokenFile(_ url: URL) -> String? {
    guard let d = try? Data(contentsOf: url),
          let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty else { return nil }
    return s
}

/// The calling agent's own token (`secrets/agents/<slug>.token`) when it has one, else the shared token.
func readTokenWithSource() -> (token: String, source: String)? {
    if let name = clientName, let slug = agentSlug(name),
       let t = readTokenFile(secrets.appendingPathComponent("agents/\(slug).token")) { return (t, "agent") }
    return readTokenFile(secrets.appendingPathComponent("mcp_token")).map { ($0, "shared") }
}

func readToken() -> String? { readTokenWithSource()?.token }

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

/// The agent behind this bridge: `--agent <name>` wins, otherwise the `clientInfo.name` the
/// client sends in `initialize`. Forwarded to the app as `X-Kronos-Client` so a task an agent
/// writes says which agent wrote it.
var clientName: String? = {
    guard let i = args.firstIndex(of: "--agent"), i + 1 < args.count else { return nil }
    let name = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}()
let nameIsFixed = clientName != nil

/// What a header may carry: printable ASCII only, so a hostile name cannot split the request.
func headerSafe(_ s: String) -> String {
    String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }.prefix(40))
}

if args.contains("--whoami") {
    // Answers without launching the app: `ssh <mac> kronos-mcp --agent hermes --whoami` is how
    // a remote agent checks that the whole path (ssh, bridge, app) is wired.
    print("kronos-mcp \(version)")
    print("agent: \(clientName.map(headerSafe) ?? "none (taken from the client's initialize)")")
    print("app: \(app?.path ?? "not found")")
    switch readEndpoint() {
    case .some(let (e, alive)): print("endpoint: \(alive ? "running" : "stale") port=\(e.port)")
    case .none: print("endpoint: absent")
    }
    print("token present: \(readToken() == nil ? "no" : "yes")")
    print("token source: \(readTokenWithSource()?.source ?? "none")")
    exit(0)
}
if args.contains("--doctor") {
    print("app: \(app?.path ?? "not found (run the helper from inside Kronos.app)")")
    print("bundle id: \(bid ?? "unknown")")
    print("secrets dir: \(secrets.path)")
    switch readEndpoint() {
    case .some(let (e, alive)): print("endpoint: \(alive ? "running" : "stale") pid=\(e.pid) port=\(e.port)")
    case .none: print("endpoint: absent")
    }
    print("token present: \(readToken() == nil ? "no" : "yes")")
    print("token source: \(readTokenWithSource()?.source ?? "none")")
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
    if let name = clientName.map(headerSafe), !name.isEmpty { r.setValue(name, forHTTPHeaderField: "X-Kronos-Client") }
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
    if method == "initialize", !nameIsFixed,
       let info = (msg["params"] as? [String: Any])?["clientInfo"] as? [String: Any],
       let name = info["name"] as? String, !name.isEmpty {
        clientName = name
    }
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

// MARK: - events (session-start digest)

/// `kronos-mcp events --agent <name> [--format md|json] [--ack] [--since N]`: what the person did
/// with this agent's tasks since it last asked. Meant for a SessionStart hook, so it never launches
/// the app: with Kronos not running it prints nothing and exits 0. Nothing to report prints nothing.
func runEvents() -> Never {
    guard clientName != nil else {
        log("events needs --agent <name>"); exit(2)
    }
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let format = value("--format") ?? "md"
    guard ["md", "json"].contains(format) else { log("--format must be md or json"); exit(2) }
    let ack = args.contains("--ack")
    guard let (endpoint, alive) = readEndpoint(), alive else {
        log("Kronos is not running; nothing to report")
        exit(0)
    }
    guard let token = readToken() else { log(disabledMessage); exit(1) }

    func call(_ tool: String, _ arguments: [String: Any]) -> [String: Any]? {
        let rpc: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": tool, "arguments": arguments]]
        guard let body = try? JSONSerialization.data(withJSONObject: rpc) else { return nil }
        switch post(endpoint, token: token, body: body, timeout: 30) {
        case .ok(200, let data, _):
            guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = top["result"] as? [String: Any] else { log("unexpected answer from Kronos"); exit(1) }
            let structured = result["structuredContent"] as? [String: Any] ?? [:]
            if (result["isError"] as? Bool) == true {
                log("\(structured["error"] as? String ?? "ERROR"): \(structured["message"] as? String ?? "")")
                exit(1)
            }
            return structured
        case .ok(401, _, _): log("the access token was rejected; reconnect from Settings > MCP"); exit(1)
        case .ok(let code, _, _): log("HTTP \(code)"); exit(1)
        case .refused, .timedOut: log("Kronos did not answer"); exit(1)
        case .failed(let m): log(m); exit(1)
        }
    }

    var since = value("--since")
    var digests: [String] = []
    var lastJSON: [String: Any] = [:]
    var cursor = ""
    for _ in 0..<5 {
        var arguments: [String: Any] = ["format": "md", "limit": 200]
        if let since { arguments["since"] = since }
        guard let page = call("events_poll", arguments) else { exit(1) }
        lastJSON = page
        cursor = page["cursor"] as? String ?? cursor
        if let d = page["digest"] as? String, !d.isEmpty { digests.append(d) }
        if (page["more"] as? Bool) != true { break }
        since = cursor
    }
    if format == "json" {
        if !digests.isEmpty || !((lastJSON["events"] as? [Any])?.isEmpty ?? true),
           let d = try? JSONSerialization.data(withJSONObject: lastJSON, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) { print(s) }
    } else if !digests.isEmpty {
        print(digests.joined(separator: "\n\n"))
    }
    if ack, !digests.isEmpty, !cursor.isEmpty { _ = call("events_ack", ["upTo": cursor]) }
    exit(0)
}

if args.first == "events" { runEvents() }

// Sequential on purpose (one request at a time; clients that pipeline get ordered
// replies, upgrade to a serial queue per id only if a slow tool call blocks others).
while let line = readLine(strippingNewline: true) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    handle(line)
}
