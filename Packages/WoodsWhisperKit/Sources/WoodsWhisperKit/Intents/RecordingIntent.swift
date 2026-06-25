import Foundation
import Combine

/// Bridges an external "new recording" request — from an App Intent, a watch complication, an iOS
/// Control / Lock Screen button, the Action Button, Siri, or a `woodswhisper://record` deep link —
/// into the running app. The app observes `pending` and presents/starts the recorder.
///
/// A plain in-process singleton is sufficient: every trigger either runs the intent with the app
/// open (`openAppWhenRun`) or opens the app via a deep link, so the launcher is always set in the
/// app's own process.
@MainActor
public final class RecordingLauncher: ObservableObject {
    public static let shared = RecordingLauncher()
    @Published public var pending = false
    public init() {}
    public func request() { pending = true }
}

/// URL that triggers a new recording when opened (used by the watch complication / lock-screen
/// widget via `widgetURL`). Handle it with `.onOpenURL` in the app.
public let woodsWhisperRecordURL = URL(string: "woodswhisper://record")!

#if canImport(AppIntents)
import AppIntents

/// Starts a new recording in Woods Whisper. Backs the iOS Control / Lock Screen button and is
/// surfaced to Siri/Spotlight via each app's `AppShortcutsProvider`. `openAppWhenRun` brings the
/// app forward so capture happens in the app's own process.
@available(iOS 16.0, watchOS 9.0, *)
public struct StartRecordingIntent: AppIntent {
    public static var title: LocalizedStringResource = "New Recording"
    public static var description = IntentDescription("Start a new voice recording in Woods Whisper.")
    public static var openAppWhenRun = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        RecordingLauncher.shared.request()
        return .result()
    }
}
#endif
