import SwiftUI
import WoodsWhisperKit

/// Watch settings: choose where recordings go (paired iPhone vs. a directly-paired iPad) and
/// manage the iPad pairing.
struct WatchSettingsView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var sendToiPad = WatchSettings.shared.transport != .phoneSession
    @State private var pairedLink = WatchSettings.shared.deviceLink

    var body: some View {
        List {
            Section("Send recordings to") {
                Picker("Destination", selection: $sendToiPad) {
                    Text("iPhone").tag(false)
                    Text("iPad (direct)").tag(true)
                }
                .onChange(of: sendToiPad) { _, toiPad in
                    // "iPad" uses whatever transport pairing established (Bluetooth or WiFi).
                    WatchSettings.shared.transport = toiPad
                        ? (pairedLink?.transport ?? .localNetwork)
                        : .phoneSession
                }
            }

            if let link = pairedLink {
                Section("Paired iPad") {
                    Text(link.displayName).font(.headline)
                    Text(link.transport == .bluetooth ? "Connected over Bluetooth" : "Connected over WiFi")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Forget iPad", role: .destructive) {
                        WatchSettings.shared.deviceLink = nil
                        pairedLink = nil
                        sendToiPad = false
                        WatchSettings.shared.transport = .phoneSession
                    }
                }
            }

            Section {
                NavigationLink {
                    WatchPairingView(onPaired: {
                        pairedLink = WatchSettings.shared.deviceLink
                        sendToiPad = true
                    })
                } label: {
                    Label(pairedLink == nil ? "Pair with iPad" : "Re-pair iPad",
                          systemImage: "applewatch.radiowaves.left.and.right")
                }
            } footer: {
                Text("On the iPad: Settings → “Receive directly from Watch” → Pair Watch, then "
                     + "type the 5-digit code. Works over WiFi or Bluetooth (no WiFi needed).")
            }
        }
        .navigationTitle("Settings")
    }
}
