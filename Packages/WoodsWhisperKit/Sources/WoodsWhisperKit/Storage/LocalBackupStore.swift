import Foundation

/// Mirrors the user's text into a folder they pick in Settings — a `WoodsWhisper` folder created
/// inside their choice, holding `Inbox/` (one Markdown file per Inbox recording, named by capture
/// timestamp) and `Documents/` (one Markdown file per document, named by its title).
///
/// Audio is deliberately left out: this is a readable, portable copy of the words, not a second
/// copy of the app's storage. Every save through `DocumentStore` schedules a sync; writes are
/// coalesced, only files whose contents actually changed are rewritten, and the newest version
/// overwrites the previous one (no history is kept — yet).
///
/// The chosen folder lives outside the app's sandbox, so it's persisted as a security-scoped
/// bookmark and access is held open for as long as backup is on.
@MainActor
public final class LocalBackupStore: ObservableObject {

    /// The folder created inside the user's chosen folder — everything is written under here, so
    /// the app never scatters files into a directory the user also keeps their own things in.
    public static let rootFolderName = "WoodsWhisper"

    /// Display name of the chosen folder, or nil when backup is off.
    @Published public private(set) var folderName: String?

    /// When the last successful sync finished.
    @Published public private(set) var lastBackupAt: Date?

    /// The most recent failure (unreachable folder, write error), cleared by the next success.
    @Published public private(set) var lastError: String?

    public var isEnabled: Bool { folderURL != nil }

    /// The user's chosen folder. Security-scoped access is held open while it's set.
    private var folderURL: URL?
    private var isAccessing = false

    /// Relative paths written by the previous sync, so files orphaned by a rename or a delete can
    /// be pruned without ever touching a file the app didn't write itself.
    private var manifest: Set<String> = []

    private var pendingSync: Task<Void, Never>?

    /// How long to coalesce document changes before writing. Edits land in the store paragraph by
    /// paragraph; one write per pause is plenty and keeps the picked folder (often a synced one)
    /// from churning.
    private static let debounce: Duration = .milliseconds(1200)

    private let defaults: UserDefaults

    private enum Key {
        static let bookmark = "ww.backupFolderBookmark"
        static let manifest = "ww.backupManifest"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        manifest = Set(defaults.stringArray(forKey: Key.manifest) ?? [])
        restoreFolder()
    }

    // MARK: Choosing the folder

    /// Adopt the folder the user picked (a security-scoped URL from the folder importer): persist a
    /// bookmark to it and start accessing it. The caller follows this with a sync to populate it.
    public func setFolder(_ url: URL) throws {
        let bookmark = try Self.bookmarkData(for: url)
        defaults.set(bookmark, forKey: Key.bookmark)
        // A different folder starts empty: forget what was written into the old one rather than
        // pruning files there (or deleting same-named files here the app didn't write).
        setManifest([])
        beginAccess(to: url)
        lastError = nil
        lastBackupAt = nil
        wwLog("Local backup folder set to “\(url.lastPathComponent)”", .general)
    }

    /// Turn backup off. Files already written are left where they are — they're the user's backup.
    public func clearFolder() {
        pendingSync?.cancel()
        pendingSync = nil
        endAccess()
        defaults.removeObject(forKey: Key.bookmark)
        setManifest([])
        lastError = nil
        lastBackupAt = nil
        wwLog("Local backup turned off", .general)
    }

    // MARK: Syncing

    /// Note that the documents changed; the write happens once changes stop arriving.
    public func scheduleSync(documents: [Document], inboxTitle: String) {
        guard isEnabled else { return }
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self.write(MarkdownBackup.plan(for: documents, inboxTitle: inboxTitle))
        }
    }

    /// Write the mirror right away (folder just chosen, "Back Up Now", app launch).
    public func syncNow(documents: [Document], inboxTitle: String) {
        guard isEnabled else { return }
        pendingSync?.cancel()
        pendingSync = Task {
            await self.write(MarkdownBackup.plan(for: documents, inboxTitle: inboxTitle))
        }
    }

    private func write(_ plan: [String: String]) async {
        guard let root = folderURL?.appendingPathComponent(Self.rootFolderName, isDirectory: true)
        else { return }

        let previous = manifest
        let result = await Task.detached(priority: .utility) {
            Self.writeToDisk(plan: plan, root: root, previous: previous)
        }.value

        setManifest(Set(plan.keys))
        lastError = result.error
        if let error = result.error {
            wwLog("Local backup failed: \(error)", .error)
        } else {
            lastBackupAt = Date()
            if result.written > 0 || result.removed > 0 {
                wwLog("Local backup wrote \(result.written) file(s)"
                      + (result.removed > 0 ? ", removed \(result.removed)" : ""), .general)
            }
        }
    }

    private struct SyncResult: Sendable {
        var written = 0
        var removed = 0
        var error: String?
    }

    /// The file work, off the main actor. Security-scoped access is process-wide, so the scope the
    /// store holds open covers these writes.
    private nonisolated static func writeToDisk(plan: [String: String],
                                                root: URL,
                                                previous: Set<String>) -> SyncResult {
        var result = SyncResult()
        let fm = FileManager.default

        do {
            for folder in [MarkdownBackup.inboxFolderName, MarkdownBackup.documentsFolderName] {
                try fm.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true),
                                       withIntermediateDirectories: true)
            }
        } catch {
            result.error = error.localizedDescription
            return result
        }

        for (path, contents) in plan {
            let url = root.appendingPathComponent(path)
            // Skip files whose contents already match, so editing one document doesn't rewrite
            // (and re-date) every other file in the folder.
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
                continue
            }
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
                result.written += 1
            } catch {
                result.error = error.localizedDescription
            }
        }

        // Prune only what a previous sync wrote and this one no longer covers — a renamed or
        // deleted document — so nothing else in the folder is ever removed.
        for stale in previous.subtracting(plan.keys) {
            if (try? fm.removeItem(at: root.appendingPathComponent(stale))) != nil {
                result.removed += 1
            }
        }

        return result
    }

    // MARK: Folder access

    /// Re-open the folder chosen in a previous session from its bookmark.
    private func restoreFolder() {
        guard let data = defaults.data(forKey: Key.bookmark) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else {
            lastError = "The backup folder couldn't be opened. Choose it again below."
            wwLog("Backup folder bookmark could not be resolved", .error)
            return
        }
        beginAccess(to: url)
        if isStale, let refreshed = try? Self.bookmarkData(for: url) {
            defaults.set(refreshed, forKey: Key.bookmark)
        }
    }

    private static func bookmarkData(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData()
    }

    private func beginAccess(to url: URL) {
        endAccess()
        isAccessing = url.startAccessingSecurityScopedResource()
        folderURL = url
        folderName = url.lastPathComponent
    }

    private func endAccess() {
        if isAccessing, let folderURL { folderURL.stopAccessingSecurityScopedResource() }
        isAccessing = false
        folderURL = nil
        folderName = nil
    }

    private func setManifest(_ paths: Set<String>) {
        manifest = paths
        defaults.set(Array(paths), forKey: Key.manifest)
    }
}
