// Delivers agent events that nobody is polling for: an HTTPS webhook (HMAC-signed), an ntfy
// message on its own topic, or a local command that gets the event JSON on stdin. The state
// machine (retry schedule, dead after 24 h) lives in KronosCore (`WebhookDispatcher`); this file
// is the transport and the timer. Targets are set only in Settings > Agents, never over MCP.

import Foundation
import KronosCore

/// Sends one message over the network or to a local process.
struct URLSessionDeliveryTransport: DeliveryTransport {
    func send(_ message: DeliveryMessage, to target: DeliveryTarget, secret: String?) async -> Bool {
        switch target {
        case .webhook(let url):
            var r = URLRequest(url: url, timeoutInterval: 15)
            r.httpMethod = "POST"
            r.httpBody = message.body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(message.kind, forHTTPHeaderField: "X-Kronos-Event")
            r.setValue(String(message.seq), forHTTPHeaderField: "X-Kronos-Seq")
            if let secret, !secret.isEmpty {
                let t = Int(Date().timeIntervalSince1970)
                r.setValue(WebhookSigner.header(secret: secret, timestamp: t, body: message.body), forHTTPHeaderField: "X-Kronos-Signature")
            }
            return await post(r)
        case .ntfy(let url):
            var r = URLRequest(url: url, timeoutInterval: 15)
            r.httpMethod = "POST"
            // ntfy headers are ASCII: anything else in the title is dropped rather than failing the send.
            let title = String(message.title.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }.prefix(120))
            if !title.isEmpty { r.setValue(title, forHTTPHeaderField: "Title") }
            r.httpBody = Data((message.note ?? message.kind).utf8)
            return await post(r)
        case .command(let argv):
            return await run(argv, stdin: message.body)
        }
    }

    private func post(_ r: URLRequest) async -> Bool {
        guard let (_, resp) = try? await URLSession(configuration: .ephemeral).data(for: r),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Runs a fixed argv (no shell, no interpolation) with the event on stdin; true on exit 0.
    private func run(_ argv: [String], stdin body: Data) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = argv
                let input = Pipe()
                p.standardInput = input
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: false); return }
                input.fileHandleForWriting.write(body)
                try? input.fileHandleForWriting.close()
                // A command that hangs must not hold the queue forever.
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }
}

/// Keeps delivering while the app runs: syncs the activity log with the store, then lets the
/// dispatcher deliver what is due, every half minute.
@MainActor
final class WebhookDeliveryController {
    private let hub: AgentHub
    private let store: any TaskStoring
    private let dispatcher: WebhookDispatcher
    private var task: Task<Void, Never>?

    init(hub: AgentHub, store: any TaskStoring, transport: DeliveryTransport = URLSessionDeliveryTransport()) {
        self.hub = hub
        self.store = store
        self.dispatcher = WebhookDispatcher(hub: hub, transport: transport, secrets: { FileSecretStore().read($0) })
    }

    func start(interval: TimeInterval = 30) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let self { await self.pass() }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One pass: report person changes, then deliver what is due.
    func pass() async {
        // Nothing to deliver and no webhook set: skip the full scan.
        guard hub.agents().contains(where: { $0.webhookURL?.isEmpty == false }) else { return }
        hub.sync(store: store)
        await dispatcher.run(store: store)
    }
}
