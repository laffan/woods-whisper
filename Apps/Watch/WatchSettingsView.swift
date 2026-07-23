import SwiftUI
import WoodsWhisperKit

/// Watch settings: choose where recordings go (paired iPhone vs. a directly-paired iPad) and
/// manage the iPad pairing.
struct WatchSettingsView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var pairedLink = WatchSettings.shared.deviceLink

    // Single source of truth for the destination, backed by the same UserDefaults key WatchSettings
    // reads. Binding the picker straight to this (rather than a separate @State Bool) avoids the
    // two drifting apart — which is what made selecting "iPhone" snap back to "iPad".
    @AppStorage("transport") private var transport: DeviceLink.Transport = .phoneSession

    private var sendToiPad: Binding<Bool> {
        Binding(
            get: { transport != .phoneSession },
            // "iPad" uses whatever transport pairing established (Bluetooth or WiFi).
            set: { transport = $0 ? (pairedLink?.transport ?? .localNetwork) : .phoneSession }
        )
    }

    var body: some View {
        List {
            Section {
                Picker("Destination", selection: sendToiPad) {
                    Text("iPhone").tag(false)
                    Text("iPad (direct)").tag(true)
                }
            } header: {
                WatchSectionHeader("Send recordings to")
            }

            if let link = pairedLink {
                Section {
                    Text(link.displayName).font(.headline)
                    Text(link.transport == .bluetooth ? "Connected over Bluetooth" : "Connected over WiFi")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Forget iPad", role: .destructive) {
                        WatchSettings.shared.deviceLink = nil
                        pairedLink = nil
                        transport = .phoneSession
                    }
                } header: {
                    WatchSectionHeader("Paired iPad")
                }
            }

            Section {
                NavigationLink {
                    WatchPairingView(onPaired: {
                        pairedLink = WatchSettings.shared.deviceLink
                        // Pairing already set the transport to the link's; mirror it here so the
                        // picker reflects the new iPad destination immediately.
                        transport = WatchSettings.shared.deviceLink?.transport ?? .localNetwork
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
