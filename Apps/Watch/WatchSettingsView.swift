import SwiftUI
import WoodsWhisperKit

/// Watch settings: choose where recordings go (paired iPhone vs. a directly-paired iPad) and
/// manage the iPad pairing.
struct WatchSettingsView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var transport = WatchSettings.shared.transport
    @State private var pairedLink = WatchSettings.shared.deviceLink

    var body: some View {
        List {
            Section("Send recordings to") {
                Picker("Destination", selection: $transport) {
                    Text("iPhone").tag(DeviceLink.Transport.phoneSession)
                    Text("iPad (direct)").tag(DeviceLink.Transport.localNetwork)
                }
                .onChange(of: transport) { _, newValue in
                    WatchSettings.shared.transport = newValue
                }
            }

            if let link = pairedLink {
                Section("Paired iPad") {
                    Text(link.displayName).font(.headline)
                    if let host = link.host {
                        Text(host).font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Forget iPad", role: .destructive) {
                        WatchSettings.shared.deviceLink = nil
                        pairedLink = nil
                        transport = .phoneSession
                        WatchSettings.shared.transport = .phoneSession
                    }
                }
            }

            Section {
                NavigationLink {
                    WatchPairingView(onPaired: { pairedLink = WatchSettings.shared.deviceLink
                                                 transport = .localNetwork })
                } label: {
                    Label(pairedLink == nil ? "Pair with iPad" : "Re-pair iPad",
                          systemImage: "applewatch.radiowaves.left.and.right")
                }
            } footer: {
                Text("On the iPad: Settings → “Receive directly from Watch” → Pair Watch, then "
                     + "type the 5-digit code shown there.")
            }
        }
        .navigationTitle("Settings")
    }
}
