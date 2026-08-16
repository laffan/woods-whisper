import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// One row of the iOS "Recent Documents" Home Screen widget: just enough of a `Document` to draw
/// a list entry and deep-link back into the app. The full document (paragraphs, recordings,
/// audio) never leaves the app's own container.
public struct WidgetDocument: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let isPinned: Bool
    /// First non-empty body paragraph, collapsed to a single line (may be empty).
    public let preview: String

    public init(id: UUID, title: String, updatedAt: Date, isPinned: Bool, preview: String) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.preview = preview
    }
}

/// The app ⇄ widget bridge. Widgets run in their own process and can't read Application Support,
/// so the app mirrors a small JSON snapshot of the most recent documents into the shared App Group
/// container on every document change; the widget's timeline provider reads it back.
///
/// Everything degrades gracefully when the App Group isn't provisioned (e.g. the widgets target
/// was removed from the project): `containerURL` comes back nil, writes become no-ops, and the
/// widget — if present anyway — just shows its empty state.
public enum WidgetSnapshotStore {
    /// Shared container both the app and the widget extension are entitled to (see project.yml).
    public static let appGroupID = "group.com.woodswhisper.app"

    /// WidgetKit kind of the Recent Documents widget — the one timeline the app reloads.
    public static let recentDocumentsKind = "com.woodswhisper.app.widget.recentdocuments"

    /// Enough rows for the tallest large widget (an iPad's fits ~7 below the New Recording button),
    /// with a spare or two so deleting a top document doesn't leave the widget a row short.
    public static let maxDocuments = 10

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("recent-documents.json")
    }

    /// The rows the widget shows, in the same order as the Documents list: Inbox excluded, pinned
    /// documents first, then most-recently-updated. Pure, so it's testable without a container.
    public static func snapshot(of documents: [Document],
                                inboxTitle: String,
                                limit: Int = maxDocuments) -> [WidgetDocument] {
        documents
            .filter { $0.title != inboxTitle }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)
            .map { WidgetDocument(id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
                                  isPinned: $0.isPinned, preview: preview(of: $0)) }
    }

    /// A one-line preview of the document body: the first non-empty paragraph with its internal
    /// line breaks collapsed, capped so the snapshot stays small however long the paragraph is.
    /// For a graph document it's the first node the outline reaches, which is the same idea — the
    /// first thing you'd read if you opened it.
    public static func preview(of document: Document) -> String {
        let blocks: [String]
        if document.isGraph {
            // The outline's first bullet, minus its dash — that's markup, not words.
            blocks = document.outline
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
        } else {
            blocks = document.paragraphs.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let first = blocks.first { !$0.isEmpty } ?? ""
        let collapsed = first
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(160))
    }

    /// Mirror the current document set into the shared container and refresh the widget. Skips the
    /// write (and the reload) when the visible rows haven't changed, so the frequent
    /// `persistDocuments` calls while editing don't churn WidgetKit.
    public static func update(documents: [Document], inboxTitle: String) {
        guard let url = fileURL else { return }
        guard let data = try? JSONEncoder.iso.encode(snapshot(of: documents, inboxTitle: inboxTitle))
        else { return }
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try? data.write(to: url, options: .atomic)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: recentDocumentsKind)
        #endif
    }

    /// The widget side: the last snapshot the app wrote, or empty if there is none yet.
    public static func read() -> [WidgetDocument] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder.iso.decode([WidgetDocument].self, from: data)
        else { return [] }
        return rows
    }
}
