import Foundation
import Combine

/// Deep links used by the Recent Documents widget (companions to `woodsWhisperRecordURL`).
/// The small widget opens the Documents tab; a tapped row opens that document.
public let woodsWhisperDocumentsURL = URL(string: "woodswhisper://documents")!

/// `woodswhisper://document/<uuid>` — opens the app straight to one document.
///
/// It's the widget's link and the one a document's **Copy Link** / **Share Link** hands out, so a
/// document can be linked to from anywhere that follows a link: a note, a reminder, a calendar
/// event, a message to yourself. Opened, it lands on that document — the pair, for half of a joint
/// one. The id is all it carries: the title can change and the link still finds its way, and a
/// link opened on a device that doesn't have the document says so rather than guessing.
public func woodsWhisperDocumentURL(id: UUID) -> URL {
    URL(string: "woodswhisper://document/\(id.uuidString)")!
}

/// The same link as Markdown — `[Title](woodswhisper://document/<uuid>)` — for a notes app that
/// reads Markdown (Obsidian and the like), where a bare custom-scheme URL isn't always drawn as a
/// link but a Markdown one is, and reads as the document's name rather than as a string of hex.
///
/// The brackets and backslashes a title might hold are escaped, so a title like "Plan [draft]"
/// can't close the link text early. An empty title falls back to "Untitled".
public func woodsWhisperDocumentMarkdownLink(id: UUID, title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    var text = ""
    for character in trimmed.isEmpty ? "Untitled" : trimmed {
        if character == "[" || character == "]" || character == "\\" { text.append("\\") }
        // A line break would end the link; the title is one line of it.
        text.append(character.isNewline ? " " : character)
    }
    return "[\(text)](\(woodsWhisperDocumentURL(id: id).absoluteString))"
}

/// The document id carried by a `woodswhisper://document/<uuid>` URL, or nil for any other URL.
public func woodsWhisperDocumentID(from url: URL) -> UUID? {
    guard url.scheme == "woodswhisper", url.host == "document" else { return nil }
    return UUID(uuidString: url.lastPathComponent)
}

/// Bridges an external "open this document" request (the widget's deep link, or a shared document
/// link tapped in another app) into the running app, the same way `RecordingLauncher` bridges "new
/// recording". The Documents list observes `pendingDocumentID` and pushes the document, clearing it
/// once handled.
@MainActor
public final class DocumentLauncher: ObservableObject {
    public static let shared = DocumentLauncher()
    @Published public var pendingDocumentID: UUID?
    public init() {}
    public func open(_ id: UUID) { pendingDocumentID = id }
}

#if canImport(AppIntents)
import AppIntents

/// Opens one document in Woods Whisper. The widget's medium and large families link to a document
/// with `woodsWhisperDocumentURL`, but WidgetKit gives `systemSmall` a single tap target and
/// ignores per-row `Link`s — a `Button(intent:)` is the one way to make each small row tappable.
/// Like `StartRecordingIntent`, `openAppWhenRun` means `perform` runs in the app's own process,
/// so setting the shared launcher there reaches the running UI.
///
/// Not discoverable: it takes a raw document id, which is meaningless to pick in Shortcuts.
@available(iOS 17.0, *)
public struct OpenDocumentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Document"
    public static var description = IntentDescription("Open a document in Woods Whisper.")
    public static var openAppWhenRun = true
    public static var isDiscoverable = false

    @Parameter(title: "Document")
    public var documentID: String

    public init() {}

    public init(documentID: UUID) {
        self.documentID = documentID.uuidString
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: documentID) { DocumentLauncher.shared.open(id) }
        return .result()
    }
}
#endif
