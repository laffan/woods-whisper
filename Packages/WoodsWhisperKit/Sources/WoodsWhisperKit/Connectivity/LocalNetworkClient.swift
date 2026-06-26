import Foundation
import Network

/// Local-network sender that runs on the **Watch** (and can also run on iPhone/iPad) to deliver
/// recordings directly to an iPad's `LocalNetworkServer` over shared WiFi — no companion phone.
///
/// The Watch cannot browse Bonjour, so it connects to the host:port captured during pairing
/// (`DeviceLink`). Uses the same length-prefixed framing as the server.
public final class LocalNetworkClient: RecordingSender {

    private let link: DeviceLink
    private let queue = DispatchQueue(label: "WoodsWhisper.LocalClient")

    public init(link: DeviceLink) {
        self.link = link
    }

    /// We can't cheaply probe reachability without connecting; assume reachable if configured.
    public var isReachable: Bool {
        link.host != nil && link.port != nil
    }

    public func send(_ transfer: RecordingTransfer, audioURL: URL,
                     progress: (@Sendable (Double) -> Void)?) async throws {
        // The frame goes out in one `NWConnection.send` over fast WiFi, so there's no useful
        // mid-flight progress to report; `progress` is intentionally unused on this path.
        guard let host = link.host, let port = link.port,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ConnectivityError.noEndpointConfigured
        }

        let audio = try Data(contentsOf: audioURL)
        var stamped = transfer
        stamped.pairingSecret = link.pairingSecret
        stamped.byteCount = audio.count

        let header = try JSONEncoder.iso.encode(stamped)
        var frame = Data([MessageType.recording])
        var headerLength = UInt32(header.count).bigEndian
        withUnsafeBytes(of: &headerLength) { frame.append(contentsOf: $0) }
        frame.append(header)
        frame.append(audio)

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)

        // An offline iPad leaves the connection in `.waiting` indefinitely (NWConnection waits for
        // connectivity), so we both honour Task cancellation (the Watch's Cancel button) and apply a
        // timeout — otherwise the send would hang forever.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    var resumed = false
                    var timeoutItem: DispatchWorkItem?
                    func finish(_ result: Result<Void, Error>) {
                        guard !resumed else { return }
                        resumed = true
                        timeoutItem?.cancel()
                        connection.cancel()
                        continuation.resume(with: result)
                    }

                    let item = DispatchWorkItem { finish(.failure(ConnectivityError.notReachable)) }
                    timeoutItem = item
                    self.queue.asyncAfter(deadline: .now() + Self.timeout, execute: item)

                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.send(content: frame, completion: .contentProcessed { error in
                                if let error { finish(.failure(ConnectivityError.transportFailure(error))); return }
                                // Read the 1-byte ack from the server.
                                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
                                    if let byte = data?.first, byte == 1 {
                                        finish(.success(()))
                                    } else {
                                        finish(.failure(ConnectivityError.authenticationFailed))
                                    }
                                }
                            })
                        case .failed(let error):
                            finish(.failure(ConnectivityError.transportFailure(error)))
                        case .cancelled:
                            finish(.failure(ConnectivityError.notReachable))
                        default:
                            break
                        }
                    }
                    connection.start(queue: self.queue)
                }
            }
        } onCancel: {
            // Triggers `.cancelled` on the connection's queue, which resumes the continuation.
            connection.cancel()
        }
    }

    /// How long to wait for an unreachable host before giving up.
    private static let timeout: TimeInterval = 30
}
