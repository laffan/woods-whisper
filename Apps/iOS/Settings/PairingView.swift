import SwiftUI
import WoodsWhisperKit

/// Shown on the iPad. Drives the **pairing-mode** flow: tap *Start Pairing* and the iPad shows a
/// large 5-digit code for a couple of minutes. On the Watch you open *Settings → Pair with iPad*
/// and type that code — the Watch finds this iPad on the local network by itself (no IP to type,
/// no QR to scan, which a Watch can't do anyway).
struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var addresses: [String] = []
    private let name = AppSettings.shared.deviceDisplayName

    var body: some View {
        Form {
            if model.pairingCode != nil {
                activePairingSection
            } else if let paired = model.lastPairedWatch {
                successSection(watch: paired)
            } else {
                startSection
            }
            networkSection
        }
        .wwForm()
        .navigationTitle("Pair Watch")
        .onAppear { addresses = NetworkInterface.displayAddresses() }
        .onDisappear { model.cancelWatchPairing() }
    }

    // MARK: Idle — ready to start

    private var startSection: some View {
        Section {
            Button {
                model.beginWatchPairing()
            } label: {
                Label("Start Pairing", systemImage: "antenna.radiowaves.left.and.right")
            }
        } header: {
            WWSectionHeader("Pair a Watch")
        } footer: {
            WWFooter("Tap Start Pairing, then on the Watch open Woods Whisper → Settings → "
                     + "“Pair with iPad” and enter the code shown here. Connects over WiFi if both "
                     + "devices share a network, otherwise over Bluetooth — so it works off-grid with "
                     + "no WiFi at all. Keep the two devices close while pairing.")
        }
        .listRowBackground(WW.surface)
    }

    // MARK: Active — code on screen

    private var activePairingSection: some View {
        Section {
            VStack(spacing: 14) {
                Text("Enter this code on your Watch")
                    .font(.subheadline).foregroundStyle(WW.inkSecondary)
                Text(model.pairingCode ?? "")
                    .font(.system(size: 54, weight: .medium, design: .rounded).monospacedDigit())
                    .tracking(10)
                    .foregroundStyle(WW.moss)
                    .textSelection(.enabled)
                if let endsAt = model.pairingEndsAt, endsAt > Date() {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                        Text("Expires in ")
                            + Text(timerInterval: Date()...endsAt, countsDown: true)
                    }
                    .font(.caption).foregroundStyle(WW.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            Button(role: .cancel) {
                model.cancelWatchPairing()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        } footer: {
            WWFooter("On the Watch: Settings → “Pair with iPad” → type these 5 digits. "
                     + "The Watch searches the network for this iPad automatically.")
        }
        .listRowBackground(WW.surface)
    }

    // MARK: Success

    private func successSection(watch: String) -> some View {
        Section {
            Label {
                Text("Paired with \(watch)")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(WW.moss)
            }
            Button {
                model.beginWatchPairing()
            } label: {
                Label("Pair Another Watch", systemImage: "antenna.radiowaves.left.and.right")
            }
        } footer: {
            WWFooter("That Watch will now send recordings straight to this iPad whenever they're on "
                     + "the same network.")
        }
        .listRowBackground(WW.surface)
    }

    // MARK: Network details (advanced / troubleshooting)

    private var networkSection: some View {
        Section {
            LabeledContent("This iPad", value: name)
            LabeledContent("Port", value: "\(AppSettings.shared.localServerPort)")
            ForEach(addresses, id: \.self) { ip in
                LabeledContent("WiFi address", value: ip)
            }
        } header: {
            WWSectionHeader("Network Details")
        } footer: {
            WWFooter("For reference. You don't need to type any of this on the Watch — the code is "
                     + "all that's required.")
        }
        .listRowBackground(WW.surface)
    }
}
