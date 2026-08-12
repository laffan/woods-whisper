import Foundation

/// The bridge between the recording Live Activity's buttons and the recorder that's actually
/// running.
///
/// The app's recording sheet owns the `AudioRecorder`; a button pressed on the Lock Screen or in
/// the Dynamic Island can't touch it directly, so the sheet registers a handler here while it's
/// capturing and each control intent calls straight through to it. A plain in-process singleton is
/// enough because Live Activity intents are performed in the app's own process (that's what
/// `LiveActivityIntent` means), not in the widget extension's — and the app is still running, since
/// the `audio` background mode keeps it alive for the recording itself.
///
/// The handler is called *directly* rather than published for a view to observe: the press arrives
/// while the app is backgrounded behind a locked screen, which is no time to be depending on
/// SwiftUI getting around to a view update.
@MainActor
public final class RecordingRemote {
    public static let shared = RecordingRemote()

    /// The four controls the in-app recorder offers, as the Lock Screen sees them.
    public enum Action: String, Sendable {
        case pause
        case resume
        case save
        case discard
    }

    /// Set by the recorder for as long as it's capturing, and nil the rest of the time — so a press
    /// against an activity that outlived its recording does nothing, rather than something
    /// surprising.
    private var handler: (@MainActor (Action) -> Void)?

    public init() {}

    public func takeControl(_ handler: @escaping @MainActor (Action) -> Void) {
        self.handler = handler
    }

    public func releaseControl() { handler = nil }

    public func send(_ action: Action) {
        guard let handler else {
            wwLog("Ignored a Lock Screen “\(action.rawValue)” — nothing is recording", .general)
            return
        }
        wwLog("Recording “\(action.rawValue)” requested from the Lock Screen", .general)
        handler(action)
    }
}

#if os(iOS) && canImport(AppIntents)
import AppIntents

// The recorder controls the Live Activity puts on the Lock Screen and in the Dynamic Island: the
// same Pause / Continue, Save, and Discard the in-app recorder offers, so a recording started in
// the woods can be run to its end without unlocking the phone.
//
// They're `LiveActivityIntent`s rather than plain `AppIntent`s because that's the flavour the
// system performs *in the app's process* — which is the whole point here, since the live
// `AudioRecorder` lives there. None of them open the app: controlling a recording from the Lock
// Screen shouldn't demand an unlock, and `RecordingRemote` reaches the recorder without one.

public struct PauseRecordingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Pause Recording"
    public static var description = IntentDescription("Pause the recording in progress.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        RecordingRemote.shared.send(.pause)
        return .result()
    }
}

public struct ResumeRecordingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Continue Recording"
    public static var description = IntentDescription("Continue a paused recording.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        RecordingRemote.shared.send(.resume)
        return .result()
    }
}

public struct SaveRecordingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Save Recording"
    public static var description = IntentDescription("Stop the recording in progress and save it.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        RecordingRemote.shared.send(.save)
        return .result()
    }
}

/// Unlike the app's own Cancel — which asks first — this discards straight away: a locked screen is
/// nowhere to put a confirmation dialog. The button is the smallest and quietest of the three
/// because of it.
public struct DiscardRecordingIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Discard Recording"
    public static var description = IntentDescription("Discard the recording in progress.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        RecordingRemote.shared.send(.discard)
        return .result()
    }
}
#endif
