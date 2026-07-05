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

    var deviceDisplayName: String {
        get { defaults.string(forKey: Key.deviceDisplayName) ?? "Woods Whisper" }
        set { defaults.set(newValue, forKey: Key.deviceDisplayName) }
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
