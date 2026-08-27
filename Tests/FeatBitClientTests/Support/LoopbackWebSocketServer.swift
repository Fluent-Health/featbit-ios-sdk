#if canImport(Network)
import Foundation
import Network

/// Minimal WebSocket server for streaming tests. Listens on 127.0.0.1:<ephemeral>.
/// Records inbound text frames + close code/reason; sends enqueued outbound text
/// frames once a client connects.
///
/// Supports only the shape used by `StreamingDataSynchronizer`:
///  - text frames in both directions
///  - normal-closure (1000) with an optional reason
final class LoopbackWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private var connection: NWConnection?
    private let lock = NSLock()
    private var inbound: [String] = []
    private var outboundQueue: [String] = []
    private var closeCode: Int?
    private var closeReason: String?
    private let readyGroup = DispatchGroup()

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var wsURLString: String { "ws://127.0.0.1:\(port)" }

    init() throws {
        let params = NWParameters(tls: nil)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        listener = try NWListener(using: params, on: .any)
    }

    func start() {
        readyGroup.enter()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.readyGroup.leave() }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: DispatchQueue.global(qos: .userInitiated))
        _ = readyGroup.wait(timeout: .now() + 2)
    }

    private func accept(_ conn: NWConnection) {
        lock.withLock { connection = conn }
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveLoop()
                self?.drainOutbound()
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func receiveLoop() {
        guard let conn = lock.withLock({ connection }) else { return }
        conn.receiveMessage { [weak self] data, ctx, _, error in
            guard let self else { return }
            if let ctx = ctx,
               let meta = ctx.protocolMetadata.first as? NWProtocolWebSocket.Metadata {
                if meta.opcode == .close {
                    // Network.framework parses the 2-byte close status out of the frame body and
                    // exposes it via `meta.closeCode` — `data` contains only the reason bytes.
                    // Older builds of this helper mis-read the code from the first two reason
                    // bytes (e.g. "paused" → code=0x7075="pu", reason="used"). Read from the
                    // metadata instead, and take the entire `data` payload as the reason.
                    let codeInt: Int?
                    switch meta.closeCode {
                    case .protocolCode(let defined): codeInt = Int(defined.rawValue)
                    case .applicationCode(let raw): codeInt = Int(raw)
                    case .privateCode(let raw): codeInt = Int(raw)
                    @unknown default: codeInt = nil
                    }
                    let reason: String? = (data.flatMap { $0.isEmpty ? nil : String(data: $0, encoding: .utf8) })
                    self.lock.withLock {
                        self.closeCode = codeInt
                        self.closeReason = reason
                    }
                    return
                } else if meta.opcode == .text, let data,
                          let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    self.lock.withLock { self.inbound.append(text) }
                }
            }
            if error == nil { self.receiveLoop() }
        }
    }

    private func drainOutbound() {
        let msgs: [String] = lock.withLock {
            let m = outboundQueue
            outboundQueue.removeAll()
            return m
        }
        for msg in msgs { sendText(msg) }
    }

    /// Sends a text frame. If not yet connected, buffers until the client connects.
    func enqueueText(_ text: String) {
        lock.withLock { outboundQueue.append(text) }
        if let conn = lock.withLock({ connection }), conn.state == .ready {
            drainOutbound()
        }
    }

    private func sendText(_ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        lock.withLock { connection }?.send(
            content: Data(text.utf8),
            contentContext: ctx,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    func receivedInbound() -> [String] {
        lock.withLock { inbound }
    }

    func recordedClose() -> (code: Int?, reason: String?) {
        lock.withLock { (closeCode, closeReason) }
    }

    func stop() {
        lock.withLock { connection }?.cancel()
        listener.cancel()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
#endif
