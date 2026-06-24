import Foundation

/// A topic container that holds one or more `Recording`s and any model-produced text
/// transformations. iOS/iPadOS only (the Watch has a flat recordings list).
public struct Document: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    public var title: String

    public let createdAt: Date
    public var updatedAt: Date

    /// The recordings that make up this document, in capture order.
    public var recordings: [Recording]

    /// Model-produced transformations of the combined transcript, newest last.
    public var transformations: [Transformation]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        recordings: [Recording] = [],
        transformations: [Transformation] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recordings = recordings
        self.transformations = transformations
    }

    /// All recording transcripts joined, in order — the input for transformations.
    public var combinedTranscript: String {
        recordings
            .compactMap { $0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public var hasTranscribableContent: Bool {
        recordings.contains { ($0.transcript?.isEmpty == false) }
    }

    /// A single run of a prompt preset against the combined transcript.
    public struct Transformation: Identifiable, Codable, Hashable, Sendable {
        public let id: UUID
        /// Name of the preset that produced this (snapshot, so renaming a preset later
        /// doesn't rewrite history).
        public var presetName: String
        public var presetID: UUID?
        public var output: String
        /// The model's reasoning (`<think>` block), if it emitted one. Shown collapsibly in the UI;
        /// deliberately separate from `output` so it's never copied or fed into further work.
        /// Optional with a default so older saved documents (no key) decode fine.
        public var reasoning: String?
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            presetName: String,
            presetID: UUID? = nil,
            output: String,
            reasoning: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.presetName = presetName
            self.presetID = presetID
            self.output = output
            self.reasoning = reasoning
            self.createdAt = createdAt
        }
    }
}
