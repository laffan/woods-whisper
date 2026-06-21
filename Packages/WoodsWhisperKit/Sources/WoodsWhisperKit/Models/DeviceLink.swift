import Foundation

/// Describes the pairing between a Watch and a specific iOS/iPadOS device.
///
/// The Watch app is "paired with a specific iOS device" per the product spec. For the
/// iPhone companion path this is implicit in WatchConnectivity (the Watch's paired iPhone).
/// For the *direct Watch→iPad* path there is no system pairing, so we persist the iPad's
/// network endpoint here, configured once during setup (watchOS cannot browse Bonjour).
public struct DeviceLink: Codable, Hashable, Sendable {
    public enum Transport: String, Codable, Sendable {
        /// WatchConnectivity (WCSession) to the Watch's paired iPhone.
        case phoneSession
        /// Direct local-network connection to an iPad running the local server.
        case localNetwork
    }

    public var transport: Transport

    /// Human-readable name of the paired device, shown in the Watch UI.
    public var displayName: String

    /// Stable identifier for the paired iOS device.
    public var deviceID: String

    // MARK: localNetwork-only fields

    /// Host of the iPad's local server (IP like "192.168.1.42" or a resolvable name).
    public var host: String?

    /// Port the iPad's `LocalNetworkServer` listens on.
    public var port: UInt16?

    /// Shared secret established at pairing, used to authenticate the Watch to the iPad
    /// so a random device on the LAN cannot push recordings.
    public var pairingSecret: String?

    public init(
        transport: Transport,
        displayName: String,
        deviceID: String,
        host: String? = nil,
        port: UInt16? = nil,
        pairingSecret: String? = nil
    ) {
        self.transport = transport
        self.displayName = displayName
        self.deviceID = deviceID
        self.host = host
        self.port = port
        self.pairingSecret = pairingSecret
    }
}
