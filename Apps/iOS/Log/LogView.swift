import SwiftUI
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
#endif

/// Detailed, copyable activity log for the current session — model download/activation,
/// audio transfers, transcription, and transforms — to aid debugging.
struct LogView: View {
    @ObservedObject private var log = SessionLog.shared
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(log.entries) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                            .wwRow()
                    }
                }
                .wwList()
                .onChange(of: log.entries.count) { _, _ in
                    if let last = log.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .overlay {
                if log.entries.isEmpty {
                    WWEmptyState(title: "No activity yet", systemImage: "terminal")
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyAll()
                    } label: {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(role: .destructive) { log.clear() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func copyAll() {
        #if canImport(UIKit)
        UIPasteboard.general.string = log.formattedText()
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct LogRow: View {
    let entry: SessionLog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospaced())
                    .foregroundStyle(WW.inkTertiary)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(entry.category.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .textCase(.uppercase)
                        .foregroundStyle(color)
                }
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(WW.ink)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }

    /// Muted, theme-adjacent hues — enough to tell categories apart without shouting.
    private var color: Color {
        switch entry.category {
        case .error: return WW.ember
        case .model: return WW.violet
        case .transfer: return WW.slate
        case .transcription: return WW.moss
        case .transform: return WW.amber
        case .general: return WW.inkTertiary
        }
    }
}
