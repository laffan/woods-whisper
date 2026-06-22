import Foundation
import Network

/// Local-network receiver that runs on the **iPad** (or iPhone) so a Watch with no companion
/// phone can deliver recordings directly over shared WiFi.
///
/// Wire format (length-prefixed framing over TCP):
///   [4 bytes big-endian headerLength][header JSON: RecordingTransfer][audio bytes: byteCount]
///
/// The iPad also advertises the service via Bonjour for *iPad/iPhone* clients that CAN browse;
/// the Watch cannot browse Bonjour, so it connects to the host:port configured during pairing.
public final class LocalNetworkServer: RecordingReceiver {

    public var onReceive: (@MainActor (RecordingTransfer, Data) -> Void)?

    /// Secret the sender must present (set at pairing). If nil, no auth is enforced.
    public var expectedSecret: String?

    public let port: UInt16
    public let serviceName: String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "WoodsWhisper.LocalServer")

    public init(port: UInt16 = 0, serviceName: String = "Woods Whisper") {
        self.port = port
        self.serviceName = serviceName
    }

    /// The actual port the listener bound to (useful when `port` was 0 / auto-assigned).
    public private(set) var boundPort: UInt16?

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true     // allows AWDL/peer-to-peer WiFi if available

        let nwPort = port == 0 ? nil : NWEndpoint.Port(rawValue: port)
        let listener = nwPort != nil
            ? try NWListener(using: parameters, on: nwPort!)
            : try NWListener(using: parameters)

        // Advertise for Bonjour-capable peers (iPad/iPhone). Watch ignores this and dials direct.
        listener.service = NWListener.Service(name: serviceName, type: "_woodswhisper._tcp")

        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.boundPort = listener.port?.rawValue }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeaderLength(on: connection)
    }

    private func receiveHeaderLength(on connection: NWConnection) {
        receiveExactly(4, on: connection) { [weak self] data in
            guard let self, let data else { connection.cancel(); return }
            let headerLength = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.receiveHeader(length: Int(headerLength), on: connection)
        }
    }

    private func receiveHeader(length: Int, on connection: NWConnection) {
        receiveExactly(length, on: connection) { [weak self] data in
            guard let self, let data,
                  let transfer = try? JSONDecoder.iso.decode(RecordingTransfer.self, from: data)
            else { connection.cancel(); return }

            if let expected = self.expectedSecret, transfer.pairingSecret != expected {
                wwLog("Rejected local-network sender “\(transfer.recording.name)”: bad pairing secret", .error)
                self.send(ack: false, on: connection)   // reject unauthenticated sender
                return
            }
            wwLog("Incoming local-network recording “\(transfer.recording.name)” "
                  + "(\(transfer.byteCount) bytes)…", .transfer)
            self.receivePayload(for: transfer, on: connection)
        }
    }

    private func receivePayload(for transfer: RecordingTransfer, on connection: NWConnection) {
        receiveExactly(transfer.byteCount, on: connection) { [weak self] data in
            guard let self, let data else { connection.cancel(); return }
            let handler = self.onReceive
            Task { @MainActor in handler?(transfer, data) }
            self.send(ack: true, on: connection)
        }
    }

    private func send(ack ok: Bool, on connection: NWConnection) {
        let byte = Data([ok ? 1 : 0])
        connection.send(content: byte, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Accumulate exactly `count` bytes (Network delivers in arbitrary chunks).
    private func receiveExactly(_ count: Int,
                                on connection: NWConnection,
                                accumulated: Data = Data(),
                                completion: @escaping (Data?) -> Void) {
        if count == 0 { completion(Data()); return }
        let remaining = count - accumulated.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { chunk, _, isComplete, error in
            var acc = accumulated
            if let chunk { acc.append(chunk) }
            if acc.count >= count {
                completion(acc)
            } else if isComplete || error != nil {
                completion(nil)
            } else {
                self.receiveExactly(count, on: connection, accumulated: acc, completion: completion)
            }
        }
    }
}
