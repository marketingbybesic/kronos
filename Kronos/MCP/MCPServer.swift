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
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
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
        let key = ObjectIdentifier(connection)
        connections[key] = connection
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

    // MARK: - HTTP/1.1 framing (hand-parsed: one POST /mcp endpoint)

    private static let maxBodyBytes = 1 * 1024 * 1024   // 1 MB cap

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
                self.processIfComplete(connection, buffer: acc)
            }
        }
    }

    private func processIfComplete(_ connection: NWConnection, buffer: Data) {
        guard let headerEnd = Self.range(of: "\r\n\r\n", in: buffer) else {
            // Headers not fully received yet; keep reading.
            if buffer.count > Self.maxBodyBytes { respond(connection, status: 413, body: nil) }
            else { readRequest(connection, buffer: buffer) }
            return
        }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            respond(connection, status: 400, body: nil); return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { respond(connection, status: 400, body: nil); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { respond(connection, status: 400, body: nil); return }
        let method = String(parts[0])
        let path = String(parts[1])

        var headerFields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headerFields[key] = value
        }

        if let transferEncoding = headerFields["transfer-encoding"], transferEncoding.lowercased().contains("chunked") {
            respond(connection, status: 411, body: nil)
            return
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headerFields["content-length"] ?? "0") ?? 0
        guard contentLength <= Self.maxBodyBytes else {
            respond(connection, status: 413, body: nil); return
        }
        let bodyAvailable = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
        guard bodyAvailable >= contentLength else {
            readRequest(connection, buffer: buffer)   // wait for the rest of the body
            return
        }
        let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)]

        guard method == "POST", path == "/mcp" else {
            respond(connection, status: path == "/mcp" ? 405 : 404, body: nil)
            return
        }
        // A nil token (the RNG or the Keychain write failed when this was first generated)
        // must reject every request, the same as a wrong one — never treat "no token
        // available" as "no auth required".
        guard let expectedToken = token,
              BearerAuth.isAuthorized(header: headerFields["authorization"], expectedToken: expectedToken) else {
            respond(connection, status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
            return
        }

        handleJSONRPC(connection, body: Data(body))
    }

    private func handleJSONRPC(_ connection: NWConnection, body: Data) {
        let mcpRequest: MCPRequest
        do {
            mcpRequest = try MCPRequest.parse(body)
        } catch let e as MCPTransportError {
            respond(connection, status: 200, body: MCPResponse.failure(id: nil, e).encoded())
            return
        } catch {
            respond(connection, status: 200, body: MCPResponse.failure(id: nil, .parseError).encoded())
            return
        }

        guard let response = dispatcher.handle(mcpRequest) else {
            // A notification (e.g. notifications/initialized) gets no
            // JSON-RPC body, only an empty 202, per the MCP transport spec.
            respond(connection, status: 202, body: nil)
            return
        }
        respond(connection, status: 200, body: response.encoded())
        NotificationCenter.default.post(name: .kronosStoreDidChangeExternally, object: nil)
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data?) {
        let payload = body ?? Data()
        let statusText = Self.statusText(status)
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
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
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        default:  return "Error"
        }
    }

    private static func range(of needle: String, in haystack: Data) -> Range<Data.Index>? {
        haystack.range(of: Data(needle.utf8))
    }
}
