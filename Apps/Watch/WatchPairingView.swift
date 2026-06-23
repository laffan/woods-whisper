import SwiftUI
import WoodsWhisperKit

/// Five-digit code entry used to pair this Watch with an iPad. Typing five digits is realistic
/// on a Watch; once entered, the Watch searches the local network for the iPad showing that code
/// (no IP to type, no QR to scan). Works over WiFi or the iPad's Personal Hotspot.
struct WatchPairingView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    /// Called after a successful pairing so the parent can refresh its state.
    var onPaired: () -> Void = {}

    @State private var entered = ""
    @State private var outcome: Outcome?

    private enum Outcome { case success(String), failure(String) }
    private let codeLength = 5

    var body: some View {
        Group {
            if model.pairingInProgress {
                scanningView
            } else if let outcome {
                resultView(outcome)
            } else {
                entryView
            }
        }
        .navigationTitle("Pair iPad")
    }

    // MARK: Code entry

    private var entryView: some View {
        VStack(spacing: 5) {
            codeDisplay
            keypad
        }
        .padding(.horizontal, 2)
    }

    private var codeDisplay: some View {
        HStack(spacing: 4) {
            ForEach(0..<codeLength, id: \.self) { index in
                Text(index < entered.count ? String(Array(entered)[index]) : "•")
                    .font(.callout.monospacedDigit())
                    .frame(width: 17, height: 20)
                    .background(.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(index < entered.count ? .primary : .secondary)
            }
        }
    }

    private var keypad: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(1...9, id: \.self) { digit in
                keyButton("\(digit)") { append("\(digit)") }
            }
            keyButton("⌫") { if !entered.isEmpty { entered.removeLast() } }
            keyButton("0") { append("0") }
            // Trailing slot kept empty to preserve the 3-column phone-style layout.
            Color.clear.frame(height: 1)
        }
    }

    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(.bordered)
    }

    private func append(_ digit: String) {
        guard entered.count < codeLength else { return }
        entered.append(digit)
        if entered.count == codeLength {
            let code = entered
            Task { await pair(code) }
        }
    }

    private func pair(_ code: String) async {
        let success = await model.pair(code: code)
        if success {
            outcome = .success(WatchSettings.shared.deviceLink?.displayName ?? "iPad")
            onPaired()
        } else {
            outcome = .failure(model.statusMessage ?? "Couldn't find the iPad.")
            entered = ""
        }
    }

    // MARK: Scanning

    private var scanningView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Searching for iPad…").font(.caption)
            if let (tried, total) = model.scanProgress {
                Text("\(tried) / \(total)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: Result

    private func resultView(_ outcome: Outcome) -> some View {
        VStack(spacing: 12) {
            switch outcome {
            case .success(let name):
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle).foregroundStyle(.green)
                Text("Paired with \(name)").font(.caption).multilineTextAlignment(.center)
                Button("Done") { dismiss() }
            case .failure(let message):
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle).foregroundStyle(.red)
                Text(message).font(.caption2).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try Again") { self.outcome = nil }
            }
        }
        .padding()
    }
}
