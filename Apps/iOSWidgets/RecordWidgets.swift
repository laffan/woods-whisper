import WidgetKit
import SwiftUI
import ActivityKit
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

// MARK: - Recording Live Activity (Lock Screen + Dynamic Island)

/// The recorder itself, on the Lock Screen. Unlike the widgets above — which sit there always,
/// waiting to be tapped — this one appears when a recording starts and goes away when it ends, and
/// while it's up it carries every control the in-app recorder has: pause/continue, save, discard.
/// The point is the woods case: start a clip, pocket the phone, and still be able to run it to its
/// end (or bin it) without unlocking.
///
/// The counter ticks itself from `startedAt` (SwiftUI's timer text), so the app doesn't push an
/// update per second — only when the state genuinely changes. The gain meter is deliberately left
/// behind: it moves ten times a second, and Live Activity updates are rate-limited by the system.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingActivityView(context: context)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .activityBackgroundTint(WWPalette.paper)
                .activitySystemActionForegroundColor(WWPalette.moss)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingStatusLabel(isPaused: context.state.isPaused)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingElapsedText(state: context.state)
                        .font(.system(size: 17, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(context.state.isPaused ? WWPalette.inkTertiary : WWPalette.ink)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingControls(isPaused: context.state.isPaused)
                }
            } compactLeading: {
                RecordingDot(isPaused: context.state.isPaused)
            } compactTrailing: {
                RecordingElapsedText(state: context.state)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(WWPalette.ink)
                    .frame(maxWidth: 46)
            } minimal: {
                RecordingDot(isPaused: context.state.isPaused)
            }
            .widgetURL(woodsWhisperRecordURL)
        }
    }
}

/// The Lock Screen face: what's happening and where it's going, the elapsed counter, then the three
/// controls.
private struct RecordingActivityView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordingStatusLabel(isPaused: context.state.isPaused)
                Spacer(minLength: 8)
                Text(context.attributes.taskName)
                    .font(.system(size: 12))
                    .foregroundStyle(WWPalette.inkTertiary)
                    .lineLimit(1)
            }

            RecordingElapsedText(state: context.state)
                .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(context.state.isPaused ? WWPalette.inkTertiary : WWPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            RecordingControls(isPaused: context.state.isPaused)
        }
    }
}

/// "Recording" / "Paused" behind a small dot, in the app's tracked-uppercase section style.
private struct RecordingStatusLabel: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 6) {
            RecordingDot(isPaused: isPaused)
            Text(isPaused ? "Paused" : "Recording")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(WWPalette.inkSecondary)
                .lineLimit(1)
        }
    }
}

/// The ember dot that stands for "capturing" throughout the app — solid while running, hollowed out
/// to a ring while paused.
private struct RecordingDot: View {
    let isPaused: Bool

    var body: some View {
        Circle()
            .strokeBorder(WWPalette.ember, lineWidth: isPaused ? 1.5 : 4)
            .frame(width: 9, height: 9)
    }
}

/// The elapsed counter. While running it's SwiftUI's self-ticking timer text counting up from the
/// (virtual) start, so it stays live between the app's updates; paused, it's the frozen number the
/// app sent, because there's nothing left to tick.
private struct RecordingElapsedText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(state.elapsedLabel)
        } else {
            Text(state.startedAt, style: .timer)
        }
    }
}

/// Discard / Save / Pause — the in-app recorder's controls, in the same order. Each runs a
/// `LiveActivityIntent`, which the system performs in the app's own process, so the press reaches
/// the recorder that's actually running.
private struct RecordingControls: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            control("Discard", "xmark", intent: DiscardRecordingIntent(), tint: WWPalette.inkSecondary)
            control("Save", "square.and.arrow.down", intent: SaveRecordingIntent(),
                    tint: WWPalette.ember, filled: true)
            if isPaused {
                control("Continue", "play.fill", intent: ResumeRecordingIntent(), tint: WWPalette.ink)
            } else {
                control("Pause", "pause.fill", intent: PauseRecordingIntent(), tint: WWPalette.ink)
            }
        }
    }

    /// One control: a hairline-stroked capsule, or a filled ember one for Save — the same weighting
    /// the app gives its own recorder buttons.
    private func control<Intent: AppIntent>(_ title: String, _ icon: String,
                                            intent: Intent, tint: Color,
                                            filled: Bool = false) -> some View {
        Button(intent: intent) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(filled ? WWPalette.paper : tint)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(filled ? tint : .clear, in: Capsule())
            .overlay(Capsule().stroke(filled ? .clear : WWPalette.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bundle

@main
struct WoodsWhisperWidgets: WidgetBundle {
    var body: some Widget {
        RecentDocumentsWidget()
        RecordLockScreenWidget()
        RecordingLiveActivity()
        if #available(iOS 18.0, *) {
            RecordControl()
        }
    }
}
