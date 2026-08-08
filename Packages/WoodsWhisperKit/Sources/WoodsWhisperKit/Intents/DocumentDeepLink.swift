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
