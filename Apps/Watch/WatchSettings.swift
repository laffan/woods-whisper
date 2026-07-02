import Foundation
import WoodsWhisperKit

/// Persisted Watch configuration: which transport to use and, for direct-to-iPad, the paired
/// `DeviceLink` captured during setup.
final class WatchSettings {
    static let shared = WatchSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let transport = "transport"
        static let deviceLink = "deviceLink"
        static let walkingMode = "walkingMode"
        static let targetDocumentID = "targetDocumentID"
        static let documents = "syncedDocuments"
    }

    /// The document new recordings should be filed into on the iOS host, chosen in the Watch's
    /// document picker. `nil` means the Inbox (the default). Persisted so the choice survives relaunch.
    var targetDocumentID: UUID? {
        get { defaults.string(forKey: Key.targetDocumentID).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue { defaults.set(newValue.uuidString, forKey: Key.targetDocumentID) }
            else { defaults.removeObject(forKey: Key.targetDocumentID) }
        }
    }

    /// The most recent document list synced from the iPhone, cached so the picker is populated at
    /// launch before a fresh sync arrives.
    var documents: [DocumentDescriptor] {
        get {
            guard let data = defaults.data(forKey: Key.documents) else { return [] }
            return (try? JSONDecoder.iso.decode([DocumentDescriptor].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder.iso.encode(newValue) {
                defaults.set(data, forKey: Key.documents)
            }
        }
    }

    /// When on, recordings are *not* auto-sent after capture (handy on a walk with no iPad nearby).
    /// They queue up and the user sends them all at once later. Stored under the same key the
    /// Watch UI reads via `@AppStorage("walkingMode")`.
    var walkingMode: Bool {
        get { defaults.bool(forKey: Key.walkingMode) }
        set { defaults.set(newValue, forKey: Key.walkingMode) }
    }

    /// `.phoneSession` (default) uses the paired iPhone; `.localNetwork` sends straight to iPad.
    var transport: DeviceLink.Transport {
        get { defaults.string(forKey: Key.transport).flatMap(DeviceLink.Transport.init) ?? .phoneSession }
        set { defaults.set(newValue.rawValue, forKey: Key.transport) }
    }

    var deviceLink: DeviceLink? {
        get {
            guard let data = defaults.data(forKey: Key.deviceLink) else { return nil }
            return try? JSONDecoder.iso.decode(DeviceLink.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder.iso.encode(value) {
                defaults.set(data, forKey: Key.deviceLink)
            } else {
                defaults.removeObject(forKey: Key.deviceLink)
            }
        }
    }
}
