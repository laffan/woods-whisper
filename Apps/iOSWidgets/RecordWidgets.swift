import WidgetKit
import SwiftUI
import AppIntents
import WoodsWhisperKit

// MARK: - Timeline

struct RecordEntry: TimelineEntry {
    let date: Date
}

struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry { RecordEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
        completion(RecordEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        completion(Timeline(entries: [RecordEntry(date: .now)], policy: .never))
    }
}

// MARK: - Lock Screen widget (iOS 17+)

/// A Lock Screen accessory widget that opens Woods Whisper and starts a new recording (via the
/// `woodswhisper://record` deep link).
struct RecordLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.woodswhisper.app.record.lockscreen",
                            provider: RecordProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title3)
            }
            .widgetURL(woodsWhisperRecordURL)
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("New Recording")
        .description("Start a new recording.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Control (iOS 18+ — Control Center / Lock Screen / Action Button)

@available(iOS 18.0, *)
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.woodswhisper.app.record.control") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("New Recording", systemImage: "mic.fill")
            }
        }
        .displayName("New Recording")
    }
}

// MARK: - Bundle

@main
struct WoodsWhisperWidgets: WidgetBundle {
    var body: some Widget {
        RecordLockScreenWidget()
        if #available(iOS 18.0, *) {
            RecordControl()
        }
    }
}
