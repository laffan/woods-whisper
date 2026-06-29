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

    /// True when this clip was captured via "Revise" (replacing a body paragraph) rather than as
    /// part of the original document. Revisions are set aside in their own section and, on
    /// "Reset with Originals", appended below the body under a "--- Revisions ---" heading.
    public var isRevision: Bool

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
        status: Status = .pending,
        isRevision: Bool = false
    ) {
        self.id = id
        self.name = name ?? Recording.defaultName(for: createdAt, duration: duration, byteCount: nil)
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.sampleRate = sampleRate
        self.origin = origin
        self.sourceDeviceID = sourceDeviceID
        self.transcript = transcript
        self.status = status
        self.isRevision = isRevision
    }

    // Custom decoding so recordings saved (or transmitted) by older builds — which had no
    // `isRevision` key — still load: the missing key defaults to false rather than failing.
    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, duration, audioFileName, sampleRate, origin,
             sourceDeviceID, transcript, status, isRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        audioFileName = try c.decode(String.self, forKey: .audioFileName)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        origin = try c.decode(Origin.self, forKey: .origin)
        sourceDeviceID = try c.decodeIfPresent(String.self, forKey: .sourceDeviceID)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        status = try c.decode(Status.self, forKey: .status)
        isRevision = try c.decodeIfPresent(Bool.self, forKey: .isRevision) ?? false
    }

    /// The default, two-line display name:
    ///
    ///     Jun 24, 2026, 3:45 PM
    ///     0:07 - 28 KB
    ///
    /// `byteCount` (the audio file size) is included when known at capture time.
    public static func defaultName(for date: Date, duration: TimeInterval, byteCount: Int?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        var second = durationLabel(duration)
        if let byteCount {
            second += " - " + ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        }
        return formatter.string(from: date) + "\n" + second
    }

    /// `m:ss` for a duration in seconds.
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Size in bytes of the file at `url`, if it exists.
    public static func fileSize(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }
}
