#if os(iOS)
import Foundation
import Combine
import MultipeerConnectivity

/// Sends Woods Whisper documents straight into Woods Whisper on another iPhone or iPad nearby, and
/// receives them, over MultipeerConnectivity — which finds the other device and moves the file over
/// peer-to-peer WiFi or Bluetooth, with no network and no internet.
///
/// AirDrop can't do this job any more: since iOS 17 a file AirDropped to a device is saved to Files'
/// Downloads folder rather than handed to the app that owns its type, and Apple has said that's
/// intended. Here the receiving app is handed the `.wwdoc` itself, so it can import it at once — and
/// ask before replacing a document of the same name.
///
/// Every device advertises while Woods Whisper is in the foreground; the sending device browses
/// only while its Send sheet is open. A device that hasn't sent here before is asked about first
/// (`requests`): **Accept** takes this one delivery, **Always Accept** takes this one and every
/// later one from that device without asking. Sessions are encrypted.
@MainActor
public final class NearbyDocumentTransfer: NSObject, ObservableObject {
    /// Bonjour service type: `_ww-docs._tcp` / `_ww-docs._udp`, both listed under the app's
    /// `NSBonjourServices`.
    public static let serviceType = "ww-docs"

    /// Another device running Woods Whisper, found while browsing.
    public struct Device: Identifiable, Hashable {
        /// This install's stable id — the same across launches and renames.
        public let deviceID: String
        public let name: String
        let peerID: MCPeerID
        public var id: String { deviceID }
    }

    /// A device that hasn't sent here before, asking to send documents.
    public struct Request: Identifiable {
        public let id = UUID()
        public let deviceID: String
        public let deviceName: String
        /// The titles of what it wants to send (the first few).
        public let titles: [String]
        fileprivate let respond: (Bool) -> Void
    }

    /// Where a send from this device has got to.
    public struct Outgoing: Equatable {
        public enum Stage: Equatable {
            /// Asked the other device; waiting for it to take the connection.
            case connecting
            case sending
            case sent
            case failed(String)
        }
        public let deviceID: String
        public let deviceName: String
        public var stage: Stage
    }

    /// Devices found while browsing, by name.
    @Published public private(set) var devices: [Device] = []
    /// The send in progress, or the last one's outcome until the next starts.
    @Published public private(set) var outgoing: Outgoing?
    /// How far the send in progress has got, 0…1. Read it on a timer — it isn't published.
    public private(set) var outgoingProgress: Progress?
    /// Devices waiting on an answer, oldest first.
    @Published public private(set) var requests: [Request] = []
    /// "Receiving “Field Notes” from iPad…" while a document is on its way here.
    @Published public private(set) var receivingMessage: String?

    /// A document has arrived: the `.wwdoc`'s location (in this app's temporary folder — the
    /// receiver reads it, then removes it) and the name of the device it came from.
    public var onReceive: (@MainActor (URL, String) -> Void)?

    /// This install's id, sent with discovery and invitations so a device is recognised by more
    /// than its (changeable) name.
    public let deviceID: String

    private let defaults: UserDefaults
    private var peerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// The session every accepted sender joins.
    private var receiveSession: MCSession!
    /// The session this device sends over: one per send, closed when it's done.
    private var sendSession: MCSession?
    private var filesToSend: [URL] = []
    private var filesStillSending = 0
    private var receivesInFlight = 0

    private enum Key {
        static let deviceID = "nearbyDeviceID"
        static let peerID = "nearbyPeerID"
        static let trusted = "nearbyTrustedDevices"
    }

    /// What a sender says about itself when it invites this device.
    private struct Invitation: Codable {
        let deviceID: String
        let titles: [String]
    }

    public init(displayName: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: Key.deviceID) {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Key.deviceID)
        }
        peerID = Self.peerID(named: displayName, defaults: defaults)
        super.init()
        receiveSession = makeSession()
    }

    // MARK: Advertising (receiving)

    /// Be findable. The app calls this whenever it comes to the foreground.
    public func startAdvertising() {
        guard advertiser == nil else { return }
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["id": deviceID],
                                                   serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    public func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }

    /// Answer a device that asked to send. `always` remembers it, so it isn't asked about again.
    public func answer(_ request: Request, accept: Bool, always: Bool = false) {
        requests.removeAll { $0.id == request.id }
        if accept && always {
            var trusted = trustedDeviceIDs
            trusted.insert(request.deviceID)
            defaults.set(Array(trusted), forKey: Key.trusted)
        }
        request.respond(accept)
        wwLog("\(accept ? "Accepted" : "Declined") documents from “\(request.deviceName)”"
              + (accept && always ? " (always)" : ""), .transfer)
    }

    /// How many devices may send here without asking.
    public var trustedDeviceCount: Int { trustedDeviceIDs.count }

    /// Ask about every device again.
    public func forgetTrustedDevices() {
        defaults.removeObject(forKey: Key.trusted)
        objectWillChange.send()
    }

    private var trustedDeviceIDs: Set<String> {
        Set(defaults.stringArray(forKey: Key.trusted) ?? [])
    }

    // MARK: Browsing and sending

    /// Look for other devices. The Send sheet calls this while it's open.
    public func startBrowsing() {
        guard browser == nil else { return }
        devices = []
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    public func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
        devices = []
    }

    /// Send `.wwdoc` files to `device`; `titles` are what it's told it's being sent.
    public func send(_ files: [URL], titles: [String], to device: Device) {
        guard let browser, !files.isEmpty else { return }
        cancelSend()
        let session = makeSession()
        sendSession = session
        filesToSend = files
        outgoing = Outgoing(deviceID: device.deviceID, deviceName: device.name, stage: .connecting)
        let context = try? JSONEncoder().encode(Invitation(deviceID: deviceID,
                                                           titles: Array(titles.prefix(5))))
        // Long enough for someone to pick the other device up and answer the question it asks.
        browser.invitePeer(device.peerID, to: session, withContext: context, timeout: 60)
        wwLog("Sending \(files.count) document(s) to “\(device.name)”…", .transfer)
    }

    /// Stop whatever send is in progress (or clear the last one's outcome).
    public func cancelSend() {
        sendSession?.disconnect()
        sendSession = nil
        filesToSend = []
        filesStillSending = 0
        outgoingProgress = nil
        outgoing = nil
    }

    // MARK: Renaming

    /// Advertise under a new name (Settings → About → Device name). Anything connected is dropped.
    public func setDisplayName(_ name: String) {
        guard Self.clipped(name) != peerID.displayName else { return }
        let wasAdvertising = advertiser != nil
        let wasBrowsing = browser != nil
        stopAdvertising()
        stopBrowsing()
        cancelSend()
        receiveSession.disconnect()
        peerID = Self.peerID(named: name, defaults: defaults)
        receiveSession = makeSession()
        if wasAdvertising { startAdvertising() }
        if wasBrowsing { startBrowsing() }
    }

    // MARK: Internals

    private func makeSession() -> MCSession {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    /// The same `MCPeerID` launch after launch, as Apple recommends — a fresh one each time shows
    /// up on other devices as a new device beside the old. A new one only when the name changes.
    private static func peerID(named name: String, defaults: UserDefaults) -> MCPeerID {
        let name = clipped(name)
        if let data = defaults.data(forKey: Key.peerID),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           saved.displayName == name {
            return saved
        }
        let fresh = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
            defaults.set(data, forKey: Key.peerID)
        }
        return fresh
    }

    /// A peer's name must be non-empty and at most 63 bytes of UTF-8, or `MCPeerID` throws.
    private static func clipped(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Woods Whisper" }
        while name.utf8.count > 63 { name.removeLast() }
        return name
    }

    private func handleInvitation(from peer: MCPeerID, context: Data?,
                                  handler: @escaping (Bool, MCSession?) -> Void) {
        guard let context,
              let invitation = try? JSONDecoder().decode(Invitation.self, from: context) else {
            handler(false, nil)
            return
        }
        let session = receiveSession!
        let respond: (Bool) -> Void = { accept in handler(accept, accept ? session : nil) }
        if trustedDeviceIDs.contains(invitation.deviceID) {
            respond(true)
            wwLog("“\(peer.displayName)” is sending documents", .transfer)
        } else {
            requests.append(Request(deviceID: invitation.deviceID, deviceName: peer.displayName,
                                    titles: invitation.titles, respond: respond))
        }
    }

    private func sessionChanged(_ session: MCSession, peer: MCPeerID, to state: MCSessionState) {
        guard session === sendSession, var current = outgoing else { return }
        switch state {
        case .connected where current.stage == .connecting:
            current.stage = .sending
            outgoing = current
            sendFiles(over: session, to: peer)
        case .notConnected where current.stage == .connecting:
            fail("“\(current.deviceName)” didn't accept. Check Woods Whisper is open on it and try again.")
        case .notConnected where current.stage == .sending:
            fail("The connection to “\(current.deviceName)” was lost.")
        default:
            break
        }
    }

    private func sendFiles(over session: MCSession, to peer: MCPeerID) {
        let total = Progress(totalUnitCount: Int64(filesToSend.count))
        outgoingProgress = total
        filesStillSending = filesToSend.count
        for file in filesToSend {
            let progress = session.sendResource(at: file, withName: file.lastPathComponent,
                                                toPeer: peer) { [weak self] error in
                Task { @MainActor in self?.fileSent(over: session, error: error) }
            }
            guard let progress else {
                fail("Couldn't start sending “\(file.deletingPathExtension().lastPathComponent)”.")
                return
            }
            total.addChild(progress, withPendingUnitCount: 1)
        }
    }

    private func fileSent(over session: MCSession, error: Error?) {
        guard session === sendSession, outgoing?.stage == .sending else { return }
        if let error {
            fail(error.localizedDescription)
            return
        }
        filesStillSending -= 1
        guard filesStillSending == 0, var current = outgoing else { return }
        current.stage = .sent
        outgoing = current
        wwLog("Sent to “\(current.deviceName)”", .transfer)
        // Leave the other side a moment to finish with the last file before hanging up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.sendSession === session else { return }
            session.disconnect()
            self.sendSession = nil
        }
    }

    private func fail(_ message: String) {
        sendSession?.disconnect()
        sendSession = nil
        filesToSend = []
        guard var current = outgoing else { return }
        current.stage = .failed(message)
        outgoing = current
        wwLog("Send to “\(current.deviceName)” failed: \(message)", .error)
    }

    private func receiveStarted(_ name: String, from peer: MCPeerID) {
        receivesInFlight += 1
        let title = (name as NSString).deletingPathExtension
        receivingMessage = "Receiving “\(title)” from \(peer.displayName)…"
    }

    private func receiveFinished(_ file: URL?, in session: MCSession, from peer: MCPeerID, error: Error?) {
        receivesInFlight = max(0, receivesInFlight - 1)
        if receivesInFlight == 0 { receivingMessage = nil }
        guard let file else {
            wwLog("Receiving from “\(peer.displayName)” failed: \(error?.localizedDescription ?? "no file")",
                  .error)
            return
        }
        // Only what came through a session this device accepted is a delivery.
        guard session === receiveSession else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        onReceive?(file, peer.displayName)
    }

    /// MultipeerConnectivity deletes a received file as soon as its delegate call returns, so it's
    /// moved somewhere of ours first — a folder of its own, keeping the sender's file name (the
    /// last path component only).
    nonisolated private static func keep(_ url: URL, named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoodsWhisperReceived", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = (name as NSString).lastPathComponent
        let destination = dir.appendingPathComponent(fileName.isEmpty ? "Document.wwdoc" : fileName)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

// MARK: - MultipeerConnectivity delegates

// MultipeerConnectivity calls these on its own queues; each hops to the main actor.

extension NearbyDocumentTransfer: MCNearbyServiceAdvertiserDelegate {
    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                       didReceiveInvitationFromPeer peerID: MCPeerID,
                                       withContext context: Data?,
                                       invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            self.handleInvitation(from: peerID, context: context, handler: invitationHandler)
        }
    }

    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                       didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.advertiser = nil
            wwLog("Couldn't advertise to nearby devices: \(error.localizedDescription)", .error)
        }
    }
}

extension NearbyDocumentTransfer: MCNearbyServiceBrowserDelegate {
    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                                    withDiscoveryInfo info: [String: String]?) {
        let id = info?["id"]
        Task { @MainActor in
            guard let id, id != self.deviceID, self.browser != nil else { return }
            self.devices.removeAll { $0.deviceID == id || $0.peerID == peerID }
            self.devices.append(Device(deviceID: id, name: peerID.displayName, peerID: peerID))
            self.devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.devices.removeAll { $0.peerID == peerID } }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser,
                                    didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            wwLog("Couldn't look for nearby devices: \(error.localizedDescription)", .error)
        }
    }
}

extension NearbyDocumentTransfer: MCSessionDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID,
                                    didChange state: MCSessionState) {
        Task { @MainActor in self.sessionChanged(session, peer: peerID, to: state) }
    }

    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName name: String,
                                    fromPeer peerID: MCPeerID, with progress: Progress) {
        Task { @MainActor in self.receiveStarted(name, from: peerID) }
    }

    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName name: String,
                                    fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        let kept: URL?
        let failure: Error?
        if error == nil, let localURL {
            do {
                kept = try Self.keep(localURL, named: name)
                failure = nil
            } catch {
                kept = nil
                failure = error
            }
        } else {
            kept = nil
            failure = error
        }
        Task { @MainActor in
            self.receiveFinished(kept, in: session, from: peerID, error: failure)
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}

    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream,
                                    withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated public func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?,
                                    fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}
#endif
