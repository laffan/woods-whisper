import Foundation
import WoodsWhisperKit

/// Lightweight persisted settings backed by UserDefaults. Holds the local-server config and
/// the selected model. The pairing secret is generated once and stored here.
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let model = "model"
        static let speechModel = "speechModel"
        static let localServerEnabled = "localServerEnabled"
        static let localServerPort = "localServerPort"
        static let pairingSecret = "pairingSecret"
        static let deviceDisplayName = "deviceDisplayName"
        static let didCompleteSetup = "didCompleteSetup"
        static let downloadedModels = "downloadedModels"
        static let preferredMicUID = "preferredMicUID"
        static let showLiveTranscription = "showLiveTranscription"
        static let allowRotation = "allowRotation"
        static let graphAutoTransformPresetID = "graphAutoTransformPresetID"
        static let transcriptTextSize = "transcriptTextSize"
        static let didPruneRetiredModels = "didPruneRetiredModels"
    }

    /// Whether the weights of models that have since left the picker have been cleared off this
    /// device. A one-shot: the lineup changed, the old downloads are gigabytes, and nothing in the
    /// UI can reach them any more.
    var didPruneRetiredModels: Bool {
        get { defaults.bool(forKey: Key.didPruneRetiredModels) }
        set { defaults.set(newValue, forKey: Key.didPruneRetiredModels) }
    }

    // MARK: Transcription text size

    /// The key `@AppStorage` reads this by, so a SwiftUI view can bind to the same number the rest
    /// of the app reads here (Settings → Display writes it; the app root hands it down as an
    /// environment value).
    static let transcriptTextSizeKey = Key.transcriptTextSize

    /// Points. The default is 17 — what a document paragraph has always been set in.
    static let defaultTranscriptTextSize: Double = 17
    /// Small enough to fit a lot on screen, large enough to read at arm's length.
    static let transcriptTextSizeRange: ClosedRange<Double> = 12...30

    /// How big transcription text is drawn: document paragraphs, Inbox transcripts and graph nodes,
    /// and — the point of it — the in-place editors those become, which set themselves from the same
    /// number so nothing changes size the moment you tap it.
    var transcriptTextSize: Double {
        get {
            let stored = defaults.double(forKey: Key.transcriptTextSize)
            guard stored > 0 else { return Self.defaultTranscriptTextSize }
            return min(max(stored, Self.transcriptTextSizeRange.lowerBound),
                       Self.transcriptTextSizeRange.upperBound)
        }
        set { defaults.set(newValue, forKey: Key.transcriptTextSize) }
    }

    /// The transform run automatically over each graph node as it's first transcribed, or nil for
    /// none. App-wide rather than per-document: a graph has no bottom bar to hang a toggle from —
    /// the canvas goes all the way down — and "how I like spoken nodes to come out" is a habit
    /// rather than a property of one mind map. (Documents and the Inbox keep their own choice.)
    var graphAutoTransformPresetID: UUID? {
        get { defaults.string(forKey: Key.graphAutoTransformPresetID).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue { defaults.set(newValue.uuidString, forKey: Key.graphAutoTransformPresetID) }
            else { defaults.removeObject(forKey: Key.graphAutoTransformPresetID) }
        }
    }

    /// Whether the interface may rotate to landscape. On (default) allows all orientations; off
    /// locks the app to portrait. Read by `AppDelegate` to answer the system's supported-orientation
    /// query, so a change takes effect as soon as the orientation is re-evaluated.
    var allowRotation: Bool {
        get { defaults.object(forKey: Key.allowRotation) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.allowRotation) }
    }

    /// Whether to show a live, continuously-updating transcript above the record toast while
    /// recording. Off by default (it runs a second capture + repeated on-device transcription).
    var showLiveTranscription: Bool {
        get { defaults.bool(forKey: Key.showLiveTranscription) }
        set { defaults.set(newValue, forKey: Key.showLiveTranscription) }
    }

    /// Chosen capture microphone (port UID), or nil for the system default.
    var preferredMicUID: String? {
        get { defaults.string(forKey: Key.preferredMicUID) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.preferredMicUID) }
            else { defaults.removeObject(forKey: Key.preferredMicUID) }
        }
    }

    var model: LanguageModelChoice {
        get { (defaults.string(forKey: Key.model)).flatMap(LanguageModelChoice.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.model) }
    }

    var speechModel: SpeechModel {
        get { (defaults.string(forKey: Key.speechModel)).flatMap(SpeechModel.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.speechModel) }
    }

    var localServerEnabled: Bool {
        get { defaults.bool(forKey: Key.localServerEnabled) }
        set { defaults.set(newValue, forKey: Key.localServerEnabled) }
    }

    /// The port the local server binds. Defaults to the shared well-known port so the Watch can
    /// find this iPad by scanning the subnet during pairing (it can't browse Bonjour). A stored
    /// value of 0 also maps to the default.
    var localServerPort: UInt16 {
        get {
            let stored = defaults.integer(forKey: Key.localServerPort)
            return stored == 0 ? LocalNetworkDefaults.port : UInt16(stored)
        }
        set { defaults.set(Int(newValue), forKey: Key.localServerPort) }
    }

    var pairingSecret: String {
        if let existing = defaults.string(forKey: Key.pairingSecret) { return existing }
        let secret = UUID().uuidString
        defaults.set(secret, forKey: Key.pairingSecret)
        return secret
    }

    /// The name this device goes by on the Watch: the Bonjour service name over WiFi, the local name
    /// the Bluetooth server advertises, and what the Watch shows once paired. Editable in
    /// **Settings → About**; it starts as the device's own name (see `systemDeviceName`), and setting
    /// it to an empty name clears the override and goes back to that.
    var deviceDisplayName: String {
        get {
            let stored = defaults.string(forKey: Key.deviceDisplayName)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? systemDeviceName : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Key.deviceDisplayName)
            } else {
                defaults.set(trimmed, forKey: Key.deviceDisplayName)
            }
        }
    }

    /// The device's own name as the system reports it — the default `deviceDisplayName` until the
    /// user types their own.
    ///
    /// It's handed in by `AppModel` at launch rather than read here: `UIDevice` is main-actor bound
    /// and this type is plain Foundation, reachable from anywhere. Note that iOS only gives an app
    /// the name the user typed in iOS Settings if it holds Apple's user-assigned-device-name
    /// entitlement; without one, this is the model name ("iPhone", "iPad") — still a truer default
    /// than the app's own name, which is the last-resort fallback.
    var systemDeviceName: String { Self.systemName ?? "Woods Whisper" }

    private static var systemName: String?

    /// Record the device's own name, as reported by the system. Ignores an empty name so the
    /// fallback stands.
    func recordSystemDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Self.systemName = trimmed
    }

    var didCompleteSetup: Bool {
        get { defaults.bool(forKey: Key.didCompleteSetup) }
        set { defaults.set(newValue, forKey: Key.didCompleteSetup) }
    }

    // MARK: Downloaded-model tracking
    //
    // Whether a model's weights have finished downloading is in-memory only on the services
    // (`isReady` reflects a loaded model, not a cached one), so it's false on every launch. We
    // record the rawValue of each model that completed a download here, keyed so switching models
    // is handled, and use it at startup to auto-load an already-downloaded model from cache rather
    // than making the user tap Download again.

    private var downloadedModels: Set<String> {
        Set(defaults.stringArray(forKey: Key.downloadedModels) ?? [])
    }

    /// True if `rawValue`'s weights were downloaded in a previous session.
    func isModelDownloaded(_ rawValue: String) -> Bool {
        downloadedModels.contains(rawValue)
    }

    /// Record that `rawValue`'s weights finished downloading (called on a successful `prepare`).
    func markModelDownloaded(_ rawValue: String) {
        var set = downloadedModels
        guard set.insert(rawValue).inserted else { return }
        defaults.set(Array(set), forKey: Key.downloadedModels)
    }

    /// Forget a model's download (called when the user taps "Remove Download" and the cached
    /// weights are deleted), so it shows as not-downloaded again.
    func unmarkModelDownloaded(_ rawValue: String) {
        var set = downloadedModels
        guard set.remove(rawValue) != nil else { return }
        defaults.set(Array(set), forKey: Key.downloadedModels)
    }
}
