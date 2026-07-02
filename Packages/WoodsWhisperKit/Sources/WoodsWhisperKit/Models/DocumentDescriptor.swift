import Foundation

/// A lightweight snapshot of a document — just enough for the Watch to show a target picker and
/// tag a recording with the document it should be filed into. The full `Document` (paragraphs,
/// recordings, audio) never leaves the iOS/iPadOS host; only its id and title are synced.
///
/// The iPhone pushes an ordered list of these to the Watch (over WatchConnectivity's application
/// context) whenever the document set changes; the Watch persists the latest list so the picker
/// works even before a fresh sync arrives.
public struct DocumentDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    public init(_ document: Document) {
        self.id = document.id
        self.title = document.title
    }
}
