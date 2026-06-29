import WidgetKit
import SwiftUI
import WoodsWhisperKit

/// A bespoke watchOS complication that starts a new recording. Tapping it opens the Woods Whisper
/// watch app via the `woodswhisper://record` deep link, which jumps to the record screen and begins
/// capturing. Supports the common accessory families so it fits round, corner, and rectangular slots.
struct RecordEntry: TimelineEntry {
    let date: Date
}

struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry { RecordEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
        completion(RecordEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        // Static glyph — never needs to refresh.
        completion(Timeline(entries: [RecordEntry(date: .now)], policy: .never))
    }
}

struct RecordComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title3)
            }
        case .accessoryCorner:
            Image(systemName: "mic.fill")
                .font(.title3)
                .widgetLabel("Dictate")
        case .accessoryInline:
            Label("New Recording", systemImage: "mic.fill")
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.title3)
                Text("New Recording")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Image(systemName: "mic.fill")
        }
    }
}

@main
struct RecordComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.woodswhisper.app.watchkitapp.record",
                            provider: RecordProvider()) { _ in
            RecordComplicationView()
                .widgetURL(woodsWhisperRecordURL)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("New Recording")
        .description("Start a new recording.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
