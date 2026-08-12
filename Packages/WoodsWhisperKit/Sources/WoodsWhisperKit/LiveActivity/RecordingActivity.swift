import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// The shape of the "recording in progress" Live Activity — the Lock Screen and Dynamic Island
/// presence the app raises while it's capturing — and so the one place the app and the widget
/// extension agree on what's on screen.
///
/// The elapsed counter is driven by `startedAt` rather than by a stream of pushed updates: the
/// widget renders it with SwiftUI's self-ticking timer text, so the app only sends a new content
/// state when something actually changes (pause, continue, stop). `startedAt` is a *virtual* start
/// — on continue it's reset to "now minus the time recorded so far" — so the counter never includes
/// the stretches the recording was paused for, exactly like the in-app counter.
public struct RecordingActivityAttributes: Codable, Hashable, Sendable {
    /// What the recorder is doing, taken from the recording sheet's own title ("New Recording",
    /// "Insert Recording", "Revise Paragraph", …), so the Lock Screen names the same task the app
    /// does.
    public var taskName: String

    public init(taskName: String) {
        self.taskName = taskName
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var isPaused: Bool

        /// The instant the (unpaused) counter should count up from — "now minus elapsed", not the
        /// moment the user tapped record.
        public var startedAt: Date

        /// Seconds recorded so far. Only read while paused: a running counter ticks itself from
        /// `startedAt`, but a paused one has to show a frozen number.
        public var elapsed: TimeInterval

        public init(isPaused: Bool, startedAt: Date, elapsed: TimeInterval) {
            self.isPaused = isPaused
            self.startedAt = startedAt
            self.elapsed = elapsed
        }

        /// `m:ss` for the frozen paused counter.
        public var elapsedLabel: String {
            let total = Int(elapsed)
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
    }
}

#if os(iOS) && canImport(ActivityKit)
extension RecordingActivityAttributes: ActivityAttributes {}

/// Raises, updates, and tears down the recording Live Activity. One recording is live at a time, so
/// one activity is: `start` is a no-op while one is already up.
///
/// Every method degrades to nothing when Live Activities are switched off for Woods Whisper in
/// iOS Settings — recording itself is never gated on the Lock Screen presence being available.
@MainActor
public final class RecordingActivityController {
    public static let shared = RecordingActivityController()

    private var activity: Activity<RecordingActivityAttributes>?

    private init() {}

    /// Whether the system will accept a Live Activity right now (the user can turn them off
    /// per-app).
    public var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Put the activity on the Lock Screen for a recording that has just started.
    public func start(taskName: String, startedAt: Date = Date()) {
        guard activity == nil, isAvailable else { return }
        // A run that was killed mid-recording can leave its activity on screen; clear any before
        // adding another, so the Lock Screen never stacks up stale recorders.
        endStrays()
        let state = RecordingActivityAttributes.ContentState(isPaused: false,
                                                             startedAt: startedAt,
                                                             elapsed: 0)
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(taskName: taskName),
                content: ActivityContent(state: state, staleDate: nil)
            )
            wwLog("Recording Live Activity started", .general)
        } catch {
            // Nothing to recover: the recording carries on without a Lock Screen presence.
            wwLog("Couldn't start the recording Live Activity: \(error.localizedDescription)", .error)
        }
    }

    /// Push the recorder's current state — called when the user pauses or continues, from either
    /// the app or the Lock Screen itself.
    public func update(isPaused: Bool, elapsed: TimeInterval) {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            isPaused: isPaused,
            startedAt: Date().addingTimeInterval(-elapsed),
            elapsed: elapsed
        )
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Take the activity down. Safe to call repeatedly and from every path that ends a recording
    /// (saved, discarded, or swiped away).
    public func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func endStrays() {
        for stray in Activity<RecordingActivityAttributes>.activities {
            Task { await stray.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
#else

/// Stand-in for platforms without ActivityKit (watchOS), so shared call sites don't need to guard.
@MainActor
public final class RecordingActivityController {
    public static let shared = RecordingActivityController()
    private init() {}
    public var isAvailable: Bool { false }
    public func start(taskName: String, startedAt: Date = Date()) {}
    public func update(isPaused: Bool, elapsed: TimeInterval) {}
    public func end() {}
}
#endif
