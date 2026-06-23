import Foundation
import SwiftUI
import WoodsWhisperKit
#if canImport(WatchKit)
import WatchKit
#endif

/// Coordinator for the Watch app: records audio, stores it locally, and sends it to the paired
/// iOS device using the configured transport (paired iPhone via WatchConnectivity, or directly
/// to an iPad over the local network).
@MainActor
final class WatchModel: ObservableObject {
    let recordings = RecordingStore(directoryName: "WatchRecordings")

    @Published var statusMessage: String?
    @Published var pendingSends: Set<UUID> = []

    /// True while a pairing scan is running; `scanProgress` is `(hostsTried, hostsTotal)`.
    @Published var pairingInProgress = false
    @Published var scanProgress: (Int, Int)?

    #if canImport(WatchConnectivity)
    private let phone = PhoneSessionTransport()
    #endif

    init() {
        #if canImport(WatchConnectivity)
        try? phone.start()
        #endif
    }

    private func sender() -> RecordingSender? {
        switch WatchSettings.shared.transport {
        case .phoneSession:
            #if canImport(WatchConnectivity)
            return phone
            #else
            return nil
            #endif
        case .localNetwork:
            guard let link = WatchSettings.shared.deviceLink else { return nil }
            return LocalNetworkClient(link: link)
        case .bluetooth:
            guard let link = WatchSettings.shared.deviceLink else { return nil }
            return BluetoothRecordingClient(link: link)
        }
    }

    // MARK: Pairing

    /// Find the iPad showing `code` and save it as the paired device. Races the two direct
    /// transports — WiFi (subnet scan) and Bluetooth — so it works whether or not a network is
    /// available; the first to answer wins and its transport is stored. Returns true on success.
    func pair(code: String) async -> Bool {
        pairingInProgress = true
        scanProgress = nil
        statusMessage = "Searching for iPad…"
        defer { pairingInProgress = false; scanProgress = nil }

        let name = Self.deviceName
        let link = await withTaskGroup(of: DeviceLink?.self) { group -> DeviceLink? in
            group.addTask {
                try? await PairingClient.pair(code: code, deviceName: name) { tried, total in
                    Task { @MainActor in self.scanProgress = (tried, total) }
                }
            }
            group.addTask {
                try? await BluetoothPairing.pair(code: code, deviceName: name)
            }
            var winner: DeviceLink?
            for await result in group {
                if let result { winner = result; group.cancelAll(); break }
            }
            return winner
        }

        guard let link else {
            statusMessage = "Couldn't find the iPad. Make sure it's showing the pairing code."
            return false
        }
        WatchSettings.shared.deviceLink = link
        WatchSettings.shared.transport = link.transport
        let how = link.transport == .bluetooth ? "Bluetooth" : "WiFi"
        statusMessage = "Paired with \(link.displayName) over \(how)."
        return true
    }

    /// This Watch's name, sent to the iPad so it can confirm which Watch paired.
    static var deviceName: String {
        #if canImport(WatchKit)
        return WKInterfaceDevice.current().name
        #else
        return "Apple Watch"
        #endif
    }

    /// Persist a freshly recorded clip and attempt to send it to the paired device.
    func store(audioURL: URL, duration: TimeInterval) {
        let fileName = audioURL.lastPathComponent
        let recording = Recording(duration: duration, audioFileName: fileName, origin: .watch)
        recordings.add(recording)
        Task { await send(recording) }
    }

    /// Send (or re-send) a recording to the paired device.
    func send(_ recording: Recording) async {
        guard let sender = sender() else {
            statusMessage = "No paired device configured."
            return
        }
        pendingSends.insert(recording.id)
        defer { pendingSends.remove(recording.id) }

        let url = recordings.audioURL(for: recording)
        let byteCount = (try? Data(contentsOf: url).count) ?? 0
        let transfer = RecordingTransfer(recording: recording, byteCount: byteCount)
        do {
            try await sender.send(transfer, audioURL: url)
            statusMessage = "Sent to \(WatchSettings.shared.deviceLink?.displayName ?? "iPhone")."
        } catch {
            statusMessage = "Send failed: \(error.localizedDescription)"
        }
    }
}
