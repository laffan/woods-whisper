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

    /// The other half of a **joint document**, if this one is half of a pair: a document and a graph
    /// shown side by side, two ways of holding the same subject rather than one container with two
    /// bodies. The link is stored on one side only — this one, the half the pair was made from —
    /// and the half it points at is reached through it instead of standing on its own in any list.
    ///
    /// Deliberately a link and not a merge: both halves stay ordinary documents, with their own
    /// recordings, backups, `.wwdoc` exports and Auto transform, and separating the pair is nothing
    /// more than clearing this.
    public var joinedID: UUID?

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
        autoTransformPresetID: UUID? = nil,
        joinedID: UUID? = nil
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
        self.joinedID = joinedID
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

    /// The ids that are the *second* half of a joint pair: another document points at each of them,
    /// so they're reached through that one rather than standing on their own in the Documents list,
    /// the Watch's target list or the widget.
    public static func jointFollowerIDs(in documents: [Document]) -> Set<UUID> {
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(documents.compactMap { document -> UUID? in
            // Only a real pair hides a half: a document and a graph, both still here. A link to
            // something missing, or to another of its own kind, hides nothing — it isn't a pair.
            guard let joined = document.joinedID, let partner = byID[joined],
                  partner.isGraph != document.isGraph else { return nil }
            return joined
        })
    }

    /// One editable block of the document body.
    public struct Paragraph: Identifiable, Codable, Hashable, Sendable {
        public let id: UUID
        public var text: String

        /// The recording whose words this section came from, when it came from one — what a long
        /// press's **Continue Recording** adds to. Survives editing the section in place (and
        /// transforming it): it's still that recording's section, said differently. Nil for text
        /// that was typed or imported, and for sections saved before sections remembered this —
        /// `continuation(forParagraph:)` finds those by their words instead.
        public var recordingID: UUID?

        public init(id: UUID = UUID(), text: String, recordingID: UUID? = nil) {
            self.id = id
            self.text = text
            self.recordingID = recordingID
        }
    }

    /// What **Continue Recording** on a section adds to: the recording it came from, and every
    /// section that recording's words became (one transcript can be several, a line each), in body
    /// order — the run the continued recording's new words will stand in for.
    ///
    /// A section that remembers its recording answers directly. One from before sections did is
    /// matched by its words: the recording whose transcript contains them, along with the other
    /// unattributed sections that transcript also contains. Nil when the section didn't come from
    /// a recording that's still here with its audio — typed, imported, moved in from another
    /// document, or rewritten past recognising.
    public func continuation(forParagraph paragraphID: UUID) -> (recording: Recording, sections: [UUID])? {
        guard let paragraph = paragraphs.first(where: { $0.id == paragraphID }) else { return nil }
        let audible = recordings.filter { !$0.isTextOnly }
        if let id = paragraph.recordingID {
            guard let recording = audible.first(where: { $0.id == id }) else { return nil }
            return (recording, paragraphs.filter { $0.recordingID == id }.map(\.id))
        }
        func squeezed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .folding(options: [.caseInsensitive], locale: nil)
        }
        let words = squeezed(paragraph.text)
        guard !words.isEmpty,
              let recording = audible.first(where: { squeezed($0.transcript ?? "").contains(words) })
        else { return nil }
        let transcript = squeezed(recording.transcript ?? "")
        let sections = paragraphs.filter { other in
            other.id == paragraphID
                || (other.recordingID == nil && !squeezed(other.text).isEmpty
                    && transcript.contains(squeezed(other.text)))
        }
        return (recording, sections.map(\.id))
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

    // MARK: Search

    /// Whether `text` contains `query`, the way a search field should read it: ignoring case and
    /// accents, and trimming the query. An empty query matches everything.
    public static func text(_ text: String, matches query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Every piece of text this document holds that a search should reach: the title, the body's
    /// paragraphs, a graph's nodes, and the recordings' transcripts.
    public var searchableTexts: [String] {
        [title] + paragraphs.map(\.text) + nodes.map(\.text) + recordings.compactMap(\.transcript)
    }

    /// Whether anything in this document matches `query`.
    public func matches(_ query: String) -> Bool {
        searchableTexts.contains { Document.text($0, matches: query) }
    }

    /// A short line around the first match of `query` in the document's content (the title aside —
    /// a search result already shows it), for a result row to show *why* it matched.
    public func searchExcerpt(for query: String, radius: Int = 40) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        for text in searchableTexts.dropFirst() {
            guard let hit = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
            else { continue }
            let start = text.index(hit.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
                ?? text.startIndex
            let end = text.index(hit.upperBound, offsetBy: radius, limitedBy: text.endIndex)
                ?? text.endIndex
            let body = text[start..<end]
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
        }
        return nil
    }

    /// One section's text dropped into another's: `inserted` placed at `offset` characters into
    /// `base` (nil, or anything past the end, appends it). Whatever whitespace sat at the seam is
    /// replaced by a single space either side, so a merge reads as one run of prose rather than two
    /// pieces pushed together — and an offset landing mid-word still leaves both words whole.
    public static func merging(_ inserted: String, into base: String, at offset: Int? = nil) -> String {
        let cut = min(max(offset ?? base.count, 0), base.count)
        let splitIndex = base.index(base.startIndex, offsetBy: cut)
        let head = base[..<splitIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = base[splitIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
        let middle = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        return [head, middle, tail].filter { !$0.isEmpty }.joined(separator: " ")
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
    ///
    /// `recordingID` is the recording the text is the words of, when it is — every section it makes
    /// remembers it (`Paragraph.recordingID`).
    public static func paragraphs(fromLinesOf text: String, recordingID: UUID? = nil) -> [Paragraph] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Paragraph(text: $0, recordingID: recordingID) }
    }

    // Custom decoding so documents saved by older builds (which stored `transformations` and no
    // `paragraphs`, and knew nothing of graphs) still load: missing keys default rather than
    // failing the decode. A document saved before graphs existed reads back as `.document`.
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, kind, paragraphs, nodes, groups, recordings, isPinned,
             autoTransformPresetID, joinedID
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
        joinedID = try c.decodeIfPresent(UUID.self, forKey: .joinedID)
    }
}
