// MCP transport. Loopback-only HTTP/1.1 server that frames JSON-RPC
// requests for MCPDispatcher (KronosCore). One process owns the
// ModelContainer: this is an in-process NWListener, never a
// second `kronos-mcp` binary.
//
// Kept deliberately small and hand-rolled: this is a single POST /mcp
// endpoint with Content-Length framing, not a general HTTP server.

import Foundation
import Network
import KronosCore

/// Binds `127.0.0.1:47311` (falling back through 47320) and serves
/// `POST /mcp` JSON-RPC requests to an `MCPDispatcher`. Never binds
/// `0.0.0.0` — `NWParameters.tcp` is given `requiredLocalEndpoint` pinned to
/// the loopback address, and every accepted connection is re-checked before
/// its first byte is read.
@MainActor
public final class MCPServer {
    public static let portRange: [UInt16] = Array(47311...47320).map { UInt16($0) }

    private let dispatcher: MCPDispatcher
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Per-connection wall-clock read deadline; fires `drop` if the request never completes.
    private var deadlines: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Fetches the bearer token. Not called until the first request actually needs to check
    /// one (`token`, below) — binding the socket must never wait on a Keychain read, and the
    /// read must never happen at all if nobody ever calls the server: the server starts
    /// listening without the token in hand and reads it on the first incoming request.
    private let tokenProvider: () -> String?
    /// Cached after the first read so only ONE Keychain access ever happens per server
    /// lifetime, however many requests arrive.
    private var cachedToken: String?

    public private(set) var isRunning = false
    public private(set) var boundPort: UInt16?
    /// The last bind failure, in case every port in `portRange` was refused — a calm string
    /// for Settings to show instead of a bare "not running".
    public private(set) var lastError: String?

    public init(dispatcher: MCPDispatcher, tokenProvider: @escaping () -> String?) {
        self.dispatcher = dispatcher
        self.tokenProvider = tokenProvider
    }

    /// The token to authenticate a request against: cached after the first call. Runs on the
    /// main actor like the rest of this type's request handling, never on app launch — this
    /// only executes once a connection has actually sent a request.
    private var token: String? {
        if let cachedToken { return cachedToken }
        let fetched = tokenProvider()
        cachedToken = fetched
        return fetched
    }

    /// Tries each port in `portRange` in order and binds the first free one.
    /// Leaves `isRunning` false and `boundPort` nil if every port is taken.
    public func start() {
        guard !isRunning else { return }
        tryBind(portsRemaining: Self.portRange)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        for (_, t) in deadlines { t.cancel() }
        deadlines.removeAll()
        isRunning = false
        boundPort = nil
    }

    private func tryBind(portsRemaining ports: [UInt16]) {
        guard let port = ports.first, let nwPort = NWEndpoint.Port(rawValue: port) else {
            isRunning = false
            boundPort = nil
            lastError = "every port in \(Self.portRange.first ?? 0)...\(Self.portRange.last ?? 0) was refused"
            return
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(MCPHTTP.bindHost), port: nwPort)
        params.allowLocalEndpointReuse = false

        let candidate: NWListener
        do {
            // `requiredLocalEndpoint` ALREADY pins host+port above — also passing `on: nwPort`
            // to the initializer hands NWListener two, redundant
            // ways to bind the same port, and NWListener(using:on:) throws POSIXErrorCode 22
            // (Invalid argument) for that combination. `requiredLocalEndpoint` alone is
            // sufficient (and is what `isLoopback` / `accept` already assume everywhere
            // else in this file); dropping `on:` here is the whole fix. The real "address
            // already in use" case for a taken port no longer throws — it now arrives as
            // the `.failed`/`.waiting` state below, so both paths still fall through to the
            // next port in range.
            candidate = try NWListener(using: params)
        } catch {
            lastError = "\(error)"
            tryBind(portsRemaining: Array(ports.dropFirst()))
            return
        }

        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.isRunning = true
                    self.boundPort = port
                    self.lastError = nil
                case .failed(let error):
                    if self.listener === candidate {
                        self.isRunning = false
                        self.boundPort = nil
                        self.lastError = "\(error)"
                        candidate.cancel()
                        if self.listener === candidate { self.listener = nil }
                        self.tryBind(portsRemaining: Array(ports.dropFirst()))
                    }
                case .cancelled:
                    if self.listener === candidate {
                        self.isRunning = false
                        self.boundPort = nil
                    }
                default:
                    break
                }
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener = candidate
        candidate.start(queue: .main)
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        // Binding to 127.0.0.1 already excludes non-loopback peers; this is
        // a defence-in-depth check against a misconfigured or future bind address.
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        // A client that opens sockets and goes quiet must not be able to hold unbounded ones.
        guard connections.count < MCPHTTP.maxConnections else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        deadlines[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(MCPHTTP.readTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.drop(key)
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self.drop(key) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        readRequest(connection, buffer: Data())
    }

    private func drop(_ key: ObjectIdentifier) {
        deadlines.removeValue(forKey: key)?.cancel()
        connections[key]?.cancel()
        connections.removeValue(forKey: key)
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr): return addr == .loopback
            case .name(let name, _): return name == "localhost" || name == "127.0.0.1"
            default: return false
            }
        }
        return false
    }

    // MARK: - HTTP/1.1 framing (parsing lives in KronosCore `MCPHTTPParser`)

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                var acc = buffer
                if let data { acc.append(data) }
                if error != nil || (isComplete && acc.isEmpty) {
                    connection.cancel()
                    return
                }
                if !self.processIfComplete(connection, buffer: acc) {
                    // Still incomplete: a peer that already closed its side will never finish it.
                    if isComplete { connection.cancel() } else { self.readRequest(connection, buffer: acc) }
                }
            }
        }
    }

    /// Returns false when more bytes are needed; true once the connection has been answered.
    private func processIfComplete(_ connection: NWConnection, buffer: Data) -> Bool {
        let head: MCPHTTPHead
        switch MCPHTTPParser.parseHead(buffer) {
        case .needMoreHeader:
            return false
        case .reject(let status):
            respond(connection, status: status, body: nil)
            return true
        case .head(let parsed):
            head = parsed
        }

        guard head.method == "POST", head.path == "/mcp" else {
            respond(connection, status: head.path == "/mcp" ? 405 : 404, body: nil)
            return true
        }
        // Browser pages can reach loopback (DNS rebinding); curl / SDK clients send no Origin.
        guard MCPEndpointFile.isOriginAllowed(head.headers["origin"]) else {
            respond(connection, status: 403, body: nil)
            return true
        }
        // Authenticate from the header block alone, before one body byte is read or decoded.
        // A nil token (the RNG or the Keychain write failed when this was first generated)
        // must reject every request, the same as a wrong one — never treat "no token
        // available" as "no auth required".
        var identity: AgentIdentity?
        if let hub = dispatcher.hub {
            // Per-agent tokens first, then the shared token as the unnamed read + propose agent.
            let header = head.headers["authorization"]
            let presented = header.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
            switch hub.authenticate(bearer: presented, legacyToken: token, client: head.headers["x-kronos-client"]) {
            case .agent(let found): identity = found
            case .denied:
                respond(connection, status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8),
                        extraHeaders: #"WWW-Authenticate: Bearer realm="Kronos""#)
                return true
            }
        } else {
            guard let expectedToken = token,
                  BearerAuth.isAuthorized(header: head.headers["authorization"], expectedToken: expectedToken) else {
                respond(connection, status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8),
                        extraHeaders: #"WWW-Authenticate: Bearer realm="Kronos""#)
                return true
            }
        }
        guard let body = MCPHTTPParser.body(in: buffer, head: head) else { return false }
        // The request is complete: from here the read deadline must not cut a held long poll short.
        deadlines.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        handleJSONRPC(connection, body: body, client: head.headers["x-kronos-client"], agent: identity)
        return true
    }

    private func handleJSONRPC(_ connection: NWConnection, body: Data, client: String?, agent: AgentIdentity?) {
        // Framing, batches, 202 for notifications / client responses: all in Core (testable).
        // An events_poll that asks to wait is held by suspension, never by blocking the main thread.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.dispatcher.handleBodyHolding(body, client: client, agent: agent)
            self.respond(connection, status: reply.status, body: reply.body)
            if reply.mutated {
                NotificationCenter.default.post(name: .kronosStoreDidChangeExternally, object: nil)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data?, extraHeaders: String? = nil) {
        let payload = body ?? Data()
        let statusText = Self.statusText(status)
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        if let extraHeaders { head += extraHeaders + "\r\n" }
        head += "Connection: close\r\n\r\n"
        var full = Data(head.utf8)
        full.append(payload)
        connection.send(content: full, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        default:  return "Error"
        }
    }
}
