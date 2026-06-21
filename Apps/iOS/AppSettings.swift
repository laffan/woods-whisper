import Foundation
import WoodsWhisperKit

/// Lightweight persisted settings backed by UserDefaults. Holds the local-server config and
/// the selected model. The pairing secret is generated once and stored here.
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let model = "model"
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

    var localServerEnabled: Bool {
        get { defaults.bool(forKey: Key.localServerEnabled) }
        set { defaults.set(newValue, forKey: Key.localServerEnabled) }
    }

    /// 0 means auto-assign; UI should surface the bound port for the Watch to be configured with.
    var localServerPort: UInt16 {
        get { UInt16(defaults.integer(forKey: Key.localServerPort)) }
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
