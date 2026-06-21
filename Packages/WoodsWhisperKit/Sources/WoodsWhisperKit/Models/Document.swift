import Foundation

/// A text document derived from a `Recording`. Lives only on iOS/iPadOS (the Watch has no
/// documents section). Holds the raw transcription plus any model-transformed variants.
public struct Document: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    public var title: String

    public let createdAt: Date
    public var updatedAt: Date

    /// The recording this document was transcribed from, if still present.
    public var sourceRecordingID: UUID?

    /// Raw Parakeet transcription, kept verbatim so transformations can always be re-run.
    public var transcript: String

    /// Model-produced transformations of the transcript, newest last.
    public var transformations: [Transformation]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceRecordingID: UUID? = nil,
        transcript: String,
        transformations: [Transformation] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceRecordingID = sourceRecordingID
        self.transcript = transcript
        self.transformations = transformations
    }

    /// A single run of a prompt preset against the transcript (or a prior transformation).
    public struct Transformation: Identifiable, Codable, Hashable, Sendable {
        public let id: UUID
        /// Name of the preset that produced this (snapshot, so renaming a preset later
        /// doesn't rewrite history).
        public var presetName: String
        public var presetID: UUID?
        public var output: String
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            presetName: String,
            presetID: UUID? = nil,
            output: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.presetName = presetName
            self.presetID = presetID
            self.output = output
            self.createdAt = createdAt
        }
    }
}
