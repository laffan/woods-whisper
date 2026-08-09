import Foundation
import Combine

/// Deep links used by the Recent Documents widget (companions to `woodsWhisperRecordURL`).
/// The small widget opens the Documents tab; a tapped row opens that document.
public let woodsWhisperDocumentsURL = URL(string: "woodswhisper://documents")!

/// `woodswhisper://document/<uuid>` — opens the app straight to one document.
public func woodsWhisperDocumentURL(id: UUID) -> URL {
    URL(string: "woodswhisper://document/\(id.uuidString)")!
}

/// The document id carried by a `woodswhisper://document/<uuid>` URL, or nil for any other URL.
public func woodsWhisperDocumentID(from url: URL) -> UUID? {
    guard url.scheme == "woodswhisper", url.host == "document" else { return nil }
    return UUID(uuidString: url.lastPathComponent)
}

/// Bridges an external "open this document" request (the widget's deep link) into the running
/// app, the same way `RecordingLauncher` bridges "new recording". The Documents list observes
/// `pendingDocumentID` and pushes the document, clearing it once handled.
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
