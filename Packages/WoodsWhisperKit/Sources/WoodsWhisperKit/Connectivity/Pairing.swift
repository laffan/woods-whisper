import Foundation
import Network

/// Shared defaults for the direct Watch→iPad local-network transport.
public enum LocalNetworkDefaults {
    /// Fixed TCP port the iPad's `LocalNetworkServer` binds. It must be stable and known so the
    /// Watch can find the iPad by scanning the subnet (it can't browse Bonjour), rather than
    /// having the user type an address.
    public static let port: UInt16 = 50710
}

/// First byte of every local-network frame, identifying the message that follows.
enum MessageType {
    static let recording: UInt8 = 0x01
    static let pairing: UInt8 = 0x02
}

/// Sent by the Watch to a candidate host during pairing. Authenticated by the short `code` the
/// iPad is displaying; carries the Watch's name purely for the iPad's confirmation UI.
public struct PairingRequest: Codable, Sendable {
    public var code: String
    public var deviceName: String

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

/// The iPad's reply on a successful pairing: its name, the durable secret the Watch should stamp
/// on every future transfer, and the port to send to.
public struct PairingResponse: Codable, Sendable {
    public var displayName: String
    public var token: String
    public var port: UInt16

    public init(displayName: String, token: String, port: UInt16) {
        self.displayName = displayName
        self.token = token
        self.port = port
    }
}

/// Finds and pairs with the iPad from the Watch using only the short code the iPad displays.
///
/// Because watchOS can't browse Bonjour, we sweep the local subnet (gateway/hotspot addresses
/// first, then the full range) and offer the code to each host on the well-known port. The iPad
/// that's in pairing mode validates the code and replies with a durable secret; the first such
/// reply wins and becomes the saved `DeviceLink`.
public enum PairingClient {

    /// Attempt to pair using `code`. Reports scan progress as `(hostsTried, hostsTotal)`.
    /// - Returns: a ready-to-save `DeviceLink` pointing at the iPad.
    /// - Throws: `.authenticationFailed` if a server was found but rejected the code (likely the
    ///   right iPad with a wrong/expired code), or `.notReachable` if no server answered.
    public static func pair(code: String,
                            port: UInt16 = LocalNetworkDefaults.port,
                            deviceName: String,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> DeviceLink {
        let hosts = NetworkInterface.candidateHosts()
        guard !hosts.isEmpty else { throw ConnectivityError.notReachable }

        let total = hosts.count
        let batchSize = 16
        var scanned = 0
        var sawRejection = false

        var index = 0
        while index < hosts.count {
            try Task.checkCancellation()   // a racing transport (BLE) may have already won
            let batch = Array(hosts[index ..< min(index + batchSize, hosts.count)])
            let outcomes = await withTaskGroup(of: AttemptOutcome.self) { group -> [AttemptOutcome] in
                for host in batch {
                    group.addTask {
                        await attemptPair(host: host, port: port, code: code,
                                          deviceName: deviceName, timeout: 1.2)
                    }
                }
                var acc: [AttemptOutcome] = []
                for await outcome in group { acc.append(outcome) }
                return acc
            }

            scanned += batch.count
            progress?(min(scanned, total), total)

            for outcome in outcomes {
                switch outcome {
                case .paired(let link): return link
                case .rejected: sawRejection = true
                case .miss: break
                }
            }
            index += batchSize
        }

        throw sawRejection ? ConnectivityError.authenticationFailed : ConnectivityError.notReachable
    }

    // MARK: - Single host attempt

    private enum AttemptOutcome {
        case paired(DeviceLink)
        case rejected       // a server answered but refused the code
        case miss           // no server / timeout / malformed reply
    }

    private static func attemptPair(host: String,
                                    port: UInt16,
                                    code: String,
                                    deviceName: String,
                                    timeout: TimeInterval) async -> AttemptOutcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let reqData = try? JSONEncoder.iso.encode(PairingRequest(code: code, deviceName: deviceName))
        else { return .miss }

        var frame = Data([MessageType.pairing])
        var length = UInt32(reqData.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(reqData)

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "WoodsWhisper.Pair")

        return await withCheckedContinuation { (continuation: CheckedContinuation<AttemptOutcome, Never>) in
            var resumed = false
            func finish(_ outcome: AttemptOutcome) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: outcome)
            }

            queue.asyncAfter(deadline: .now() + timeout) { finish(.miss) }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: frame, completion: .contentProcessed { error in
                        if error != nil { finish(.miss); return }
                        // Read the 1-byte accept/reject, then (on accept) the response frame.
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
                            guard let ack = data?.first else { finish(.miss); return }
                            guard ack == 1 else { finish(.rejected); return }
                            receiveFramed(on: connection) { payload in
                                guard let payload,
                                      let resp = try? JSONDecoder.iso.decode(PairingResponse.self, from: payload)
                                else { finish(.miss); return }
                                let link = DeviceLink(transport: .localNetwork,
                                                      displayName: resp.displayName,
                                                      deviceID: resp.displayName,
                                                      host: host,
                                                      port: resp.port,
                                                      pairingSecret: resp.token)
                                finish(.paired(link))
                            }
                        }
                    })
                case .failed, .cancelled:
                    finish(.miss)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}

/// Read a `[4-byte big-endian length][payload]` frame from a connection.
func receiveFramed(on connection: NWConnection, completion: @escaping (Data?) -> Void) {
    receiveExactly(4, on: connection) { lengthData in
        guard let lengthData else { completion(nil); return }
        let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        receiveExactly(length, on: connection, completion: completion)
    }
}

/// Accumulate exactly `count` bytes from a connection (Network delivers in arbitrary chunks).
func receiveExactly(_ count: Int,
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
            receiveExactly(count, on: connection, accumulated: acc, completion: completion)
        }
    }
}
