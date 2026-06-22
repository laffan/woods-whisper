import Foundation

/// A single captured audio clip. Created on either the Watch or an iOS/iPadOS device, and
/// (on iOS/iPadOS) held inside a `Document`. Carries its own transcription.
///
/// The audio bytes live on disk (managed by the store); this struct is the lightweight,
/// `Codable` metadata that is persisted as JSON and transmitted between devices.
public struct Recording: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    /// User-facing name. Defaults to a timestamp; renamable.
    public var name: String

    /// When the audio was captured.
    public let createdAt: Date

    /// Duration in seconds, if known at creation time.
    public var duration: TimeInterval

    /// Filename (not full path) of the audio payload inside the store's audio directory.
    /// e.g. "<uuid>.m4a".
    public var audioFileName: String

    /// Sample rate of the captured audio. We record at 16 kHz mono (Parakeet's input format).
    public var sampleRate: Double

    /// Which device originated the recording, for provenance in the UI.
    public var origin: Origin

    /// Identifier of the device this recording is paired to / synced from.
    public var sourceDeviceID: String?

    /// On-device speech-to-text result (nil until transcribed).
    public var transcript: String?

    /// Lifecycle of this recording's transcription.
    public var status: Status

    public enum Origin: String, Codable, Sendable {
        case watch
        case phone
        case pad
    }

    public enum Status: String, Codable, Sendable {
        case pending        // captured, not yet transcribed
        case transcribing
        case done
        case failed
    }

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String,
        sampleRate: Double = 16_000,
        origin: Origin,
        sourceDeviceID: String? = nil,
        transcript: String? = nil,
        status: Status = .pending
    ) {
        self.id = id
        self.name = name ?? Recording.defaultName(for: createdAt)
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.sampleRate = sampleRate
        self.origin = origin
        self.sourceDeviceID = sourceDeviceID
        self.transcript = transcript
        self.status = status
    }

    public static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Recording \(formatter.string(from: date))"
    }
}
