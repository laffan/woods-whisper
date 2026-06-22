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
                        LogRow(entry: entry).id(entry.id)
                    }
                }
                .listStyle(.plain)
                .onChange(of: log.entries.count) { _, _ in
                    if let last = log.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .overlay {
                if log.entries.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "terminal")
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(entry.category.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color.opacity(0.2), in: Capsule())
                    .foregroundStyle(color)
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch entry.category {
        case .error: return .red
        case .model: return .purple
        case .transfer: return .blue
        case .transcription: return .green
        case .transform: return .orange
        case .general: return .gray
        }
    }
}
