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
    }

    var model: GemmaModel {
        get { (defaults.string(forKey: Key.model)).flatMap(GemmaModel.init(rawValue:)) ?? .default }
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
}
