import SwiftUI

/// The in-progress recording readout shared by the iOS record surfaces: an elapsed-time counter,
/// a live gain meter, and a pause/continue toggle to its right. The actual start/stop lives with
/// the caller; this is just the running display + pause control.
public struct RecordingBar: View {
    private let elapsed: TimeInterval
    private let level: Float
    private let isPaused: Bool
    private let onTogglePause: () -> Void

    public init(elapsed: TimeInterval, level: Float, isPaused: Bool,
                onTogglePause: @escaping () -> Void) {
        self.elapsed = elapsed
        self.level = level
        self.isPaused = isPaused
        self.onTogglePause = onTogglePause
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(Self.timeString(elapsed))
                .monospacedDigit()
                .font(.headline)
                .foregroundStyle(isPaused ? .secondary : .primary)
            LevelMeter(level: level)
            Button(action: onTogglePause) {
                Image(systemName: isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isPaused ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused ? "Continue recording" : "Pause recording")
        }
    }

    public static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
