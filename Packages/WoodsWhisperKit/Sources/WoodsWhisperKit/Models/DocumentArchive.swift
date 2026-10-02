import Foundation

/// A self-contained, portable snapshot of a single `Document` — its edited body (paragraphs), its
/// recordings' metadata and transcripts, **and** the raw audio bytes for every recording — packed
/// into one file so a document can be shared between devices (AirDrop, Files, Messages, …).
///
/// Unlike `DocumentDescriptor` (id + title only, synced to the Watch), the archive carries
/// everything needed to reconstruct the document on another device with no network round-trip. It's
/// encoded as a binary property list — a single `.wwdoc` file — which stores the audio `Data`
/// blobs compactly without base64 inflation and needs no third-party zip dependency.
public struct DocumentArchive: Codable, Sendable {
    /// File extension for exported archives.
    public static let fileExtension = "wwdoc"

    /// Uniform Type Identifier declared by the iOS app (see `UTExportedTypeDeclarations`).
    public static let contentType = "com.woodswhisper.document"

    /// Bumped if the archive layout changes so importers can migrate rather than fail.
    ///
    /// 2 — carries the other half of a joint document (`partner`). Version 1 archives simply have
    /// none, and older builds reading a version 2 archive ignore it and import the one half.
    public static let currentVersion = 2

    public var version: Int

    /// The document itself: title, edited paragraphs, and recording metadata (with transcripts).
    public var document: Document

    /// The other half of a joint document, when the document shared is one: a document and a
    /// graph are one subject held two ways, so the pair travels together and opens as a pair on the
    /// other device. Its recordings' audio is in `audio` alongside the document's own (every audio
    /// file name is a fresh UUID, so the two sets can't collide).
    public var partner: Document?

    /// Raw audio bytes keyed by each recording's `audioFileName`, so the importer can rehydrate the
    /// audio files that the document's recordings point at.
    public var audio: [String: Data]

    public init(document: Document,
                partner: Document? = nil,
                audio: [String: Data],
                version: Int = DocumentArchive.currentVersion) {
        self.version = version
        self.document = document
        self.partner = partner
        self.audio = audio
    }

    /// Encode to a single `.wwdoc` payload (binary plist).
    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Decode a `.wwdoc` payload produced by `encoded()`.
    public static func decode(from data: Data) throws -> DocumentArchive {
        try PropertyListDecoder().decode(DocumentArchive.self, from: data)
    }
}

/// Errors surfaced while exporting or importing a `DocumentArchive`.
public enum DocumentArchiveError: LocalizedError {
    case documentNotFound

    public var errorDescription: String? {
        switch self {
        case .documentNotFound: return "The document could not be found."
        }
    }
}
