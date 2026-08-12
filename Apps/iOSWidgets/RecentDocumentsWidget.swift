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
/// system lives in the app target and widget extensions only link WoodsWhisperKit. Shared with the
/// recording Live Activity in `RecordWidgets.swift`.
enum WWPalette {
    static let paper = dynamicColor(light: UIColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1),
                                    dark: UIColor(red: 0.086, green: 0.094, blue: 0.078, alpha: 1))
    static let ink = dynamicColor(light: UIColor(red: 0.129, green: 0.122, blue: 0.102, alpha: 1),
                                  dark: UIColor(red: 0.918, green: 0.910, blue: 0.875, alpha: 1))
    static let inkSecondary = dynamicColor(light: UIColor(red: 0.467, green: 0.455, blue: 0.420, alpha: 1),
                                           dark: UIColor(red: 0.592, green: 0.580, blue: 0.541, alpha: 1))
    static let inkTertiary = dynamicColor(light: UIColor(red: 0.659, green: 0.643, blue: 0.600, alpha: 1),
                                          dark: UIColor(red: 0.416, green: 0.408, blue: 0.376, alpha: 1))
    static let hairline = dynamicColor(light: UIColor(red: 0.890, green: 0.878, blue: 0.839, alpha: 1),
                                       dark: UIColor(red: 0.169, green: 0.180, blue: 0.157, alpha: 1))
    static let moss = dynamicColor(light: UIColor(red: 0.247, green: 0.361, blue: 0.267, alpha: 1),
                                   dark: UIColor(red: 0.576, green: 0.675, blue: 0.549, alpha: 1))
    /// Recording / destructive, as in the app: a muted ember red.
    static let ember = dynamicColor(light: UIColor(red: 0.737, green: 0.322, blue: 0.251, alpha: 1),
                                    dark: UIColor(red: 0.851, green: 0.439, blue: 0.357, alpha: 1))

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

// MARK: - Views

struct RecentDocumentsView: View {
    let entry: RecentDocumentsEntry
    @Environment(\.widgetFamily) private var family

    /// Minimum row height. The large family can afford Apple's 44pt target; small and medium are
    /// only ~126pt tall inside their margins, so their rows are sized to fit three below the
    /// button — still comfortably more than the 16pt line of text they hold, and tight enough that
    /// the titles read as a list rather than as three widely-spaced lines.
    private var rowHeight: CGFloat { family == .systemLarge ? 44 : 28 }
    private var buttonHeight: CGFloat { family == .systemLarge ? 32 : 26 }
    private let spacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            recordButton
            if entry.documents.isEmpty {
                emptyState
            } else {
                // How many rows fit is measured rather than hardcoded per family: the widget's
                // height varies by device (a large widget on an SE is ~70pt shorter than on a Pro
                // Max), and the button now takes a fixed slice off the top. The reader wraps only
                // the list, so its height is already what's left below the button.
                GeometryReader { proxy in
                    VStack(alignment: .leading, spacing: spacing) {
                        ForEach(documents(fitting: proxy.size.height)) { document in
                            tapTarget(url: woodsWhisperDocumentURL(id: document.id),
                                      intent: OpenDocumentIntent(documentID: document.id)) {
                                row(document)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// The rows that fit in `height`: n rows occupy `n * rowHeight + (n - 1) * spacing`. The half
    /// point of tolerance keeps a row that lands a rounding hair over the edge — the shorter
    /// phones sit almost exactly on the boundary at three rows, and half a point of overhang is
    /// invisible where losing the whole row is not.
    private func documents(fitting height: CGFloat) -> [WidgetDocument] {
        let count = Int((height + spacing + 0.5) / (rowHeight + spacing))
        return Array(entry.documents.prefix(max(1, count)))
    }

    /// Wraps `content` in whichever tap route the family supports: medium and large link out by
    /// URL, while systemSmall — which WidgetKit gives a single tap target, ignoring per-element
    /// `Link`s — runs an App Intent instead. Both routes do the same thing once in the app.
    @ViewBuilder
    private func tapTarget<Intent: AppIntent, Content: View>(
        url: URL, intent: Intent, @ViewBuilder content: () -> Content
    ) -> some View {
        if family == .systemSmall {
            Button(intent: intent) { content() }
                .buttonStyle(.plain)
        } else {
            Link(destination: url) { content() }
        }
    }

    /// One row sized as a tap target: the full width and at least `rowHeight` tall, with the
    /// content shape covering the whole band so taps land anywhere on it, not just on the text.
    private func row(_ document: WidgetDocument) -> some View {
        DocumentRow(document: document, family: family)
            .padding(.vertical, family == .systemLarge ? 4 : 2)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// The reserved slot at the top: starts a recording, the same action as the Lock Screen widget
    /// and the Control. A hairline-stroked capsule with a moss glyph, matching the app's own
    /// unfilled recorder control (`WWRoundIconButtonStyle`) rather than shouting over the list.
    private var recordButton: some View {
        tapTarget(url: woodsWhisperRecordURL, intent: StartRecordingIntent()) {
            HStack(spacing: 5) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("New Recording")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(WWPalette.moss)
            .frame(maxWidth: .infinity, minHeight: buttonHeight)
            .overlay(Capsule().stroke(WWPalette.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
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
                // The button above is already the call to action, so this just says what lands here.
                Text("Documents you write will show up here.")
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
