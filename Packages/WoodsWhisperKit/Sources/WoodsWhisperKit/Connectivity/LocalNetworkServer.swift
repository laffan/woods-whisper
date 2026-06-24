import Foundation
import Network

/// Local-network receiver that runs on the **iPad** (or iPhone) so a Watch with no companion
/// phone can deliver recordings directly over shared WiFi.
///
/// Wire format — every frame starts with a 1-byte message type:
///   recording (0x01): [0x01][4-byte BE headerLen][header JSON RecordingTransfer][audio bytes]
///                      → server replies [1 byte ack]
///   pairing   (0x02): [0x02][4-byte BE reqLen][PairingRequest JSON]
///                      → server replies [1 byte ack][4-byte BE respLen][PairingResponse JSON]
///
/// The iPad also advertises the service via Bonjour for *iPad/iPhone* clients that CAN browse;
/// the Watch cannot browse Bonjour, so it finds the iPad by scanning the subnet during pairing.
public final class LocalNetworkServer: RecordingReceiver {

    public var onReceive: (@MainActor (RecordingTransfer, Data) -> Void)?

    /// Called on the main actor with the Watch's name when a pairing handshake succeeds.
    public var onPairSuccess: (@MainActor (String) -> Void)?

    /// Secret the sender must present on transfers (set at pairing). If nil, no auth is enforced.
    public var expectedSecret: String?

    public let port: UInt16
    public let serviceName: String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "WoodsWhisper.LocalServer")

    // Pairing-mode state, read/written only on `queue`.
    private var pairingCode: String?
    private var pairingExpiry: Date?
    private var pairingToken: String?

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

    // MARK: Pairing mode

    /// Open a time-boxed pairing window. While open, a Watch presenting `code` is given `token`
    /// (the durable secret it stamps on future transfers) and the iPad's name/port.
    public func beginPairing(code: String, token: String, duration: TimeInterval) {
        queue.async {
            self.pairingCode = code
            self.pairingToken = token
            self.pairingExpiry = Date().addingTimeInterval(duration)
        }
    }

    public func endPairing() {
        queue.async {
            self.pairingCode = nil
            self.pairingToken = nil
            self.pairingExpiry = nil
        }
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveExactly(1, on: connection) { [weak self] data in
            guard let self, let type = data?.first else { connection.cancel(); return }
            switch type {
            case MessageType.recording: self.receiveTransferHeader(on: connection)
            case MessageType.pairing:   self.receivePairing(on: connection)
            default:                    connection.cancel()
            }
        }
    }

    // MARK: Recording transfer

    private func receiveTransferHeader(on connection: NWConnection) {
        receiveFramed(on: connection) { [weak self] data in
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

    // MARK: Pairing handshake

    private func receivePairing(on connection: NWConnection) {
        receiveFramed(on: connection) { [weak self] data in
            guard let self, let data,
                  let request = try? JSONDecoder.iso.decode(PairingRequest.self, from: data)
            else { connection.cancel(); return }
            self.handlePairing(request, on: connection)   // runs on `queue`
        }
    }

    private func handlePairing(_ request: PairingRequest, on connection: NWConnection) {
        let active = pairingCode != nil
            && Date() < (pairingExpiry ?? .distantPast)
            && request.code == pairingCode

        guard active, let token = pairingToken else {
            wwLog("Rejected pairing from “\(request.deviceName)”: wrong or expired code", .error)
            send(ack: false, on: connection)
            return
        }

        let response = PairingResponse(displayName: serviceName, token: token,
                                       port: boundPort ?? port)
        guard let payload = try? JSONEncoder.iso.encode(response) else {
            send(ack: false, on: connection)
            return
        }

        var frame = Data([1])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in connection.cancel() })

        wwLog("Paired with Watch “\(request.deviceName)”", .transfer)
        let name = request.deviceName
        let handler = onPairSuccess
        Task { @MainActor in handler?(name) }
    }

    // MARK: Replies

    private func send(ack ok: Bool, on connection: NWConnection) {
        let byte = Data([ok ? 1 : 0])
        connection.send(content: byte, completion: .contentProcessed { _ in connection.cancel() })
    }
}
