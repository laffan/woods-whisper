import Foundation

/// A single captured audio clip. Created on either the Watch or an iOS/iPadOS device.
///
/// The audio file itself lives on disk (managed by `RecordingStore`); this struct is the
/// lightweight, `Codable` metadata that is persisted as JSON and transmitted between devices.
public struct Recording: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    /// User-facing name. Defaults to a timestamp; renamable.
    public var name: String

    /// When the audio was captured.
    public let createdAt: Date

    /// Duration in seconds, if known at creation time.
    public var duration: TimeInterval

    /// Filename (not full path) of the audio payload inside the store's audio directory.
    /// e.g. "<uuid>.m4a". Resolve to a URL via `RecordingStore.audioURL(for:)`.
    public var audioFileName: String

    /// Sample rate of the captured audio. Parakeet expects 16 kHz mono; we record at 16 kHz
    /// so no resampling is needed before transcription.
    public var sampleRate: Double

    /// Which device originated the recording, for provenance in the UI.
    public var origin: Origin

    /// Identifier of the device this recording is paired to / synced from.
    public var sourceDeviceID: String?

    public enum Origin: String, Codable, Sendable {
        case watch
        case phone
        case pad
    }

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String,
        sampleRate: Double = 16_000,
        origin: Origin,
        sourceDeviceID: String? = nil
    ) {
        self.id = id
        self.name = name ?? Recording.defaultName(for: createdAt)
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.sampleRate = sampleRate
        self.origin = origin
        self.sourceDeviceID = sourceDeviceID
    }

    public static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Recording \(formatter.string(from: date))"
    }
}
