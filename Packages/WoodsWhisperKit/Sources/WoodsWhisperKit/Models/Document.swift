import Foundation

/// A coherent text document, built from an ordered list of editable `Paragraph`s, plus the raw
/// `Recording`s it was assembled from (kept in a separate "Recordings" section, not woven into the
/// body). iOS/iPadOS only (the Watch has a flat recordings list).
///
/// The body is the document the user reads and edits; recordings are the source material.
/// Re-transcribing a recording appends its transcript as a paragraph at the bottom of the body;
/// transforming rewrites paragraphs in place.
public struct Document: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    public var title: String

    public let createdAt: Date
    public var updatedAt: Date

    /// The document body: ordered, editable, reorderable text blocks.
    public var paragraphs: [Paragraph]

    /// The recordings this document was assembled from, kept separate from the body and shown in
    /// their own "Recordings" section.
    public var recordings: [Recording]

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        paragraphs: [Paragraph] = [],
        recordings: [Recording] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.paragraphs = paragraphs
        self.recordings = recordings
    }

    /// The whole body as plain text — the input for a whole-document transform.
    public var combinedText: String {
        paragraphs
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public var hasBodyText: Bool {
        paragraphs.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One editable block of the document body.
    public struct Paragraph: Identifiable, Codable, Hashable, Sendable {
        public let id: UUID
        public var text: String

        public init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Split model output (or any transcript) into paragraphs on blank lines, trimming and dropping
    /// empties, so paragraph-level operations keep working after a transform.
    public static func paragraphs(from text: String) -> [Paragraph] {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return blocks.isEmpty ? [] : blocks.map { Paragraph(text: $0) }
    }

    // Custom decoding so documents saved by older builds (which stored `transformations` and no
    // `paragraphs`) still load: missing keys default to empty rather than failing the decode.
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, paragraphs, recordings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        paragraphs = try c.decodeIfPresent([Paragraph].self, forKey: .paragraphs) ?? []
        recordings = try c.decodeIfPresent([Recording].self, forKey: .recordings) ?? []
    }
}
