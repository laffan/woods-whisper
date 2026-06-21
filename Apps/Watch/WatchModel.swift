import Foundation
import SwiftUI
import WoodsWhisperKit

/// Coordinator for the Watch app: records audio, stores it locally, and sends it to the paired
/// iOS device using the configured transport (paired iPhone via WatchConnectivity, or directly
/// to an iPad over the local network).
@MainActor
final class WatchModel: ObservableObject {
    let recordings = RecordingStore(directoryName: "WatchRecordings")

    @Published var statusMessage: String?
    @Published var pendingSends: Set<UUID> = []

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
        }
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
