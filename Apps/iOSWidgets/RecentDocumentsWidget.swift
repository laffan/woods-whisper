import WidgetKit
import SwiftUI
import UIKit
import AppIntents
import WoodsWhisperKit

// MARK: - Timeline

struct RecentDocumentsEntry: TimelineEntry {
    let date: Date
    let documents: [WidgetDocument]

    /// Sample rows for the widget gallery (and for snapshots before the app has written data).
    static var placeholder: RecentDocumentsEntry {
        RecentDocumentsEntry(date: .now, documents: [
            WidgetDocument(id: UUID(), title: "Field Notes",
                           updatedAt: .now.addingTimeInterval(-25 * 60), isPinned: true,
                           preview: "Marked the beaver dam on the north creek before the rain."),
            WidgetDocument(id: UUID(), title: "Trip Log",
                           updatedAt: .now.addingTimeInterval(-3 * 3600), isPinned: false,
                           preview: "Day three — the ridge trail is clear down to the meadow."),
            WidgetDocument(id: UUID(), title: "Bird Sightings",
                           updatedAt: .now.addingTimeInterval(-26 * 3600), isPinned: false,
                           preview: "Two kinglets and a varied thrush near the old cabin.")
        ])
    }
}

/// Reads the snapshot the app mirrors into the App Group container on every document change.
/// The timeline never expires on its own — the app reloads it explicitly whenever the snapshot
/// changes, and the rows' relative timestamps keep themselves current between reloads.
struct RecentDocumentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentDocumentsEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (RecentDocumentsEntry) -> Void) {
        completion(context.isPreview ? .placeholder : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentDocumentsEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> RecentDocumentsEntry {
        RecentDocumentsEntry(date: .now, documents: WidgetSnapshotStore.read())
    }
}

// MARK: - Palette

/// The app's "field notes" palette (see `WW` in the iOS app), restated here because the design
/// system lives in the app target and widget extensions only link WoodsWhisperKit.
private enum WWPalette {
    static let paper = dynamicColor(light: UIColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1),
                                    dark: UIColor(red: 0.086, green: 0.094, blue: 0.078, alpha: 1))
    static let ink = dynamicColor(light: UIColor(red: 0.129, green: 0.122, blue: 0.102, alpha: 1),
                                  dark: UIColor(red: 0.918, green: 0.910, blue: 0.875, alpha: 1))
    static let inkSecondary = dynamicColor(light: UIColor(red: 0.467, green: 0.455, blue: 0.420, alpha: 1),
                                           dark: UIColor(red: 0.592, green: 0.580, blue: 0.541, alpha: 1))
    static let inkTertiary = dynamicColor(light: UIColor(red: 0.659, green: 0.643, blue: 0.600, alpha: 1),
                                          dark: UIColor(red: 0.416, green: 0.408, blue: 0.376, alpha: 1))
    static let moss = dynamicColor(light: UIColor(red: 0.247, green: 0.361, blue: 0.267, alpha: 1),
                                   dark: UIColor(red: 0.576, green: 0.675, blue: 0.549, alpha: 1))

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

// MARK: - Views

struct RecentDocumentsView: View {
    let entry: RecentDocumentsEntry
    @Environment(\.widgetFamily) private var family

    /// How many rows fit each family below the header, now that every row is a comfortable tap
    /// target rather than a bare line of text. The large family trades two of its old seven rows
    /// for the extra height.
    private var rowLimit: Int {
        switch family {
        case .systemLarge: return 5
        default:           return 3
        }
    }

    /// Minimum row height. Apple's 44pt target doesn't fit three rows in the shorter families, so
    /// they get as much as the widget can spare; the large family goes the full 44.
    private var rowHeight: CGFloat {
        family == .systemLarge ? 44 : 36
    }

    private var rows: [WidgetDocument] { Array(entry.documents.prefix(rowLimit)) }

    var body: some View {
        if entry.documents.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 2) {
                header
                    .padding(.bottom, 2)
                ForEach(rows) { document in
                    if family == .systemSmall {
                        // WidgetKit ignores per-row `Link`s in systemSmall (one tap target for the
                        // whole widget), so small rows open their document through an App Intent
                        // instead. Both routes land in `DocumentLauncher`.
                        Button(intent: OpenDocumentIntent(documentID: document.id)) {
                            row(document)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Link(destination: woodsWhisperDocumentURL(id: document.id)) {
                            row(document)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// One row sized as a tap target: the full width and at least `rowHeight` tall, with the
    /// content shape covering the whole band so taps land anywhere on it, not just on the text.
    private func row(_ document: WidgetDocument) -> some View {
        DocumentRow(document: document, family: family)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var header: some View {
        Text("Documents")
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(WWPalette.inkSecondary)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(WWPalette.inkTertiary)
            Text("No documents yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WWPalette.ink)
            if family != .systemSmall {
                Text("Capture a recording to get started.")
                    .font(.system(size: 11))
                    .foregroundStyle(WWPalette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DocumentRow: View {
    let document: WidgetDocument
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if document.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(WWPalette.moss)
                }
                Text(document.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WWPalette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                if family != .systemSmall {
                    Spacer(minLength: 6)
                    Text(document.updatedAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(WWPalette.inkTertiary)
                        .lineLimit(1)
                }
            }
            if family == .systemLarge, !document.preview.isEmpty {
                Text(document.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(WWPalette.inkSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Widget

/// The one Home Screen widget: the most recently updated documents (pinned first), matching the
/// order of the app's Documents list. Rows deep-link straight into their document; the small
/// family opens the Documents tab.
struct RecentDocumentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.recentDocumentsKind,
                            provider: RecentDocumentsProvider()) { entry in
            RecentDocumentsView(entry: entry)
                .widgetURL(woodsWhisperDocumentsURL)
                .containerBackground(WWPalette.paper, for: .widget)
        }
        .configurationDisplayName("Recent Documents")
        .description("Your most recently updated documents.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
