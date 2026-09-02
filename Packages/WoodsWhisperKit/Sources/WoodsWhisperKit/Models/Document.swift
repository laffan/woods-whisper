import Foundation

/// A coherent text document, built from an ordered list of editable `Paragraph`s, plus the raw
/// `Recording`s it was assembled from (kept in a separate "Recordings" section, not woven into the
/// body). iOS/iPadOS only (the Watch has a flat recordings list).
///
/// The body is the document the user reads and edits; recordings are the source material.
/// Re-transcribing a recording appends its transcript as a paragraph at the bottom of the body;
/// transforming rewrites paragraphs in place.
///
/// A document can also be a **graph** (`kind == .graph`): the same container, but its body is a set
/// of `GraphNode`s laid out on a canvas rather than paragraphs read top to bottom. Everything
/// around the body — recordings, Auto transform, the trash, sharing, the backup mirror — is
/// unchanged, which is the point of making it a kind of document rather than a second type.
public struct Document: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID

    public var title: String

    public let createdAt: Date
    public var updatedAt: Date

    /// What this document *is* — prose or a mind map. Chosen in the New Document dialog and fixed
    /// from then on: the two have different bodies, so there's nothing sensible to convert.
    public var kind: Kind

    /// The document body: ordered, editable, reorderable text blocks. Empty in a graph document,
    /// which keeps its body in `nodes` instead.
    public var paragraphs: [Paragraph]

    /// The graph body: the nodes on the canvas of a `.graph` document. Empty in an ordinary one.
    public var nodes: [GraphNode]

    /// Rings drawn round clusters of those nodes — spatial annotation, not structure. Empty in an
    /// ordinary document, and in most graphs.
    public var groups: [GraphGroup]

    /// The recordings this document was assembled from, kept separate from the body and shown in
    /// their own "Recordings" section.
    public var recordings: [Recording]

    /// Pinned documents are held at the top of the Documents list, above the unpinned ones.
    public var isPinned: Bool

    /// The `PromptPreset` to run automatically the first time a recording in this document is
    /// transcribed ("Auto transform", the toggle at the bottom of the Inbox and of each document).
    /// Nil means off. Only the *first* transcription is transformed — re-transcribing or resetting a
    /// clip gives the original words back rather than transforming them a second time.
    public var autoTransformPresetID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        kind: Kind = .document,
        paragraphs: [Paragraph] = [],
        nodes: [GraphNode] = [],
        groups: [GraphGroup] = [],
        recordings: [Recording] = [],
        isPinned: Bool = false,
        autoTransformPresetID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kind = kind
        self.paragraphs = paragraphs
        self.nodes = nodes
        self.groups = groups
        self.recordings = recordings
        self.isPinned = isPinned
        self.autoTransformPresetID = autoTransformPresetID
    }

    /// Which body this document has.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Paragraphs, read top to bottom.
        case document
        /// Nodes on a canvas — a mind map.
        case graph
    }

    /// The whole body as plain text — what Copy, Share and a whole-document transform work on, and
    /// what the Markdown backup writes under the title. A graph has no top-to-bottom body to hand
    /// over, so it hands over its outline: the same content, in the shape the canvas already has.
    public var combinedText: String {
        switch kind {
        case .document:
            return paragraphs
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        case .graph:
            return outline
        }
    }

    public var hasBodyText: Bool {
        switch kind {
        case .document: return paragraphs.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .graph:    return nodes.contains { $0.hasText }
        }
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

    /// Split text you **wrote** — an in-place edit, an imported file, the clipboard — into
    /// paragraphs on blank lines, trimming and dropping empties, so a soft break inside a paragraph
    /// stays part of it. Text the app *produced* (a transcript, a transform's answer) splits on
    /// every line instead: see `paragraphs(fromLinesOf:)`.
    public static func paragraphs(from text: String) -> [Paragraph] {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return blocks.isEmpty ? [] : blocks.map { Paragraph(text: $0) }
    }

    /// Split text the app **produced** — a transcript, a transform's answer — into body paragraphs
    /// on *any* line break, not just blank lines.
    ///
    /// Spoken words come back as one unbroken run, but a transform can hand back several blocks — a
    /// list, points, numbered paragraphs — separated by a single newline as often as by a blank one.
    /// Filing that away as a single paragraph leaves text that *reads* as several sections but is
    /// one: no inter-paragraph "+" between them, and nothing to reorder, swipe or transform on its
    /// own. So here every line starts a paragraph of its own.
    ///
    /// Text you typed keeps the other rule — `paragraphs(from:)`, blank lines only.
    public static func paragraphs(fromLinesOf text: String) -> [Paragraph] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Paragraph(text: $0) }
    }

    // Custom decoding so documents saved by older builds (which stored `transformations` and no
    // `paragraphs`, and knew nothing of graphs) still load: missing keys default rather than
    // failing the decode. A document saved before graphs existed reads back as `.document`.
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, kind, paragraphs, nodes, groups, recordings, isPinned,
             autoTransformPresetID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .document
        paragraphs = try c.decodeIfPresent([Paragraph].self, forKey: .paragraphs) ?? []
        nodes = try c.decodeIfPresent([GraphNode].self, forKey: .nodes) ?? []
        groups = try c.decodeIfPresent([GraphGroup].self, forKey: .groups) ?? []
        recordings = try c.decodeIfPresent([Recording].self, forKey: .recordings) ?? []
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        autoTransformPresetID = try c.decodeIfPresent(UUID.self, forKey: .autoTransformPresetID)
    }
}
