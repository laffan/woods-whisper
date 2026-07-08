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
    public static let currentVersion = 1

    public var version: Int

    /// The document itself: title, edited paragraphs, and recording metadata (with transcripts).
    public var document: Document

    /// Raw audio bytes keyed by each recording's `audioFileName`, so the importer can rehydrate the
    /// audio files that the document's recordings point at.
    public var audio: [String: Data]

    public init(document: Document,
                audio: [String: Data],
                version: Int = DocumentArchive.currentVersion) {
        self.version = version
        self.document = document
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
