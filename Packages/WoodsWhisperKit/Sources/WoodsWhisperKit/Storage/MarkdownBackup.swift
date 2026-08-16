import Foundation

/// Turns the current document set into the flat Markdown mirror written to the user's backup
/// folder: one file per Inbox recording (named by its capture timestamp) and one file per
/// document (named by its title).
///
/// Pure and dependency-free — no disk access here — so the naming and formatting rules can be
/// unit-tested. `LocalBackupStore` takes the plan this produces and writes it out.
public enum MarkdownBackup {
    public static let fileExtension = "md"
    public static let inboxFolderName = "Inbox"
    public static let documentsFolderName = "Documents"

    /// The whole mirror: relative path (under the `WoodsWhisper` folder) → file contents.
    /// Text only — audio is deliberately not backed up.
    public static func plan(for documents: [Document], inboxTitle: String) -> [String: String] {
        var files: [String: String] = [:]

        let inboxRecordings = documents.filter { $0.title == inboxTitle }.flatMap(\.recordings)
        for (fileName, recording) in named(inboxRecordings,
                                           stem: { (r: Recording) in stem(for: r) },
                                           id: { (r: Recording) in r.id }) {
            files["\(inboxFolderName)/\(fileName)"] = markdown(for: recording)
        }

        let userDocuments = documents.filter { $0.title != inboxTitle }
        for (fileName, document) in named(userDocuments,
                                          stem: { (d: Document) in stem(for: d) },
                                          id: { (d: Document) in d.id }) {
            files["\(documentsFolderName)/\(fileName)"] = markdown(for: document)
        }

        return files
    }

    // MARK: File contents

    /// A document as Markdown: its title as an H1, then the body paragraphs blank-line separated.
    /// No timestamps or other volatile metadata, so a file is only rewritten when its text changed.
    ///
    /// A **graph** document renders the same way — the difference is what `combinedText` hands over:
    /// its nodes as an indented outline rather than paragraphs, so a mind map backs up (and copies,
    /// and shares) as the outline it already is.
    public static func markdown(for document: Document) -> String {
        let body = document.combinedText
        var out = "# \(document.title)\n"
        if !body.isEmpty { out += "\n\(body)\n" }
        return out
    }

    /// Several documents as one Markdown file: each rendered exactly as it is in the backup folder,
    /// separated by a blank line, so the titles are what marks where one document ends and the next
    /// begins. Backs the Documents list's batch Copy and Share, which hand over one combined file
    /// rather than several separate ones.
    public static func combined(_ documents: [Document]) -> String {
        documents.map { markdown(for: $0) }.joined(separator: "\n")
    }

    /// An Inbox recording as Markdown: capture time as an H1, a short provenance line, then the
    /// transcript (absent until the recording has been transcribed).
    public static func markdown(for recording: Recording) -> String {
        var out = "# \(headingDate(recording.createdAt))\n\n"
        out += "*\(provenance(for: recording))*\n"
        let transcript = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !transcript.isEmpty { out += "\n\(transcript)\n" }
        return out
    }

    // MARK: File names

    /// An Inbox recording's file-name stem: its creation timestamp, so the folder sorts
    /// chronologically. e.g. `2026-07-31 14-30-05`.
    public static func stem(for recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: recording.createdAt)
    }

    /// A document's file-name stem: its title, with characters that are illegal in a file name
    /// replaced.
    public static func stem(for document: Document) -> String {
        safeFileName(document.title, fallback: "Document")
    }

    /// Strip characters that are illegal (or awkward) in a file name so a title can be used as one.
    /// Falls back to `fallback` when nothing usable is left, and caps the length so a long first
    /// paragraph masquerading as a title can't overflow the filesystem's limit.
    public static func safeFileName(_ raw: String, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
        // Leading/trailing dots and spaces are legal but troublesome (". " / ".." resolve to
        // directories, trailing spaces get silently dropped by some filesystems).
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(120))
    }

    /// Pair each item with its file name, disambiguating collisions (two documents with the same
    /// title, two clips captured in the same second) with a short id suffix. *Every* member of a
    /// colliding group gets the suffix, not just the later ones, so a file's name never depends on
    /// the order the items happen to be in — otherwise re-sorting the list would rename files.
    private static func named<T>(_ items: [T],
                                 stem: (T) -> String,
                                 id: (T) -> UUID) -> [(String, T)] {
        var counts: [String: Int] = [:]
        for item in items { counts[stem(item), default: 0] += 1 }
        return items.map { item in
            let base = stem(item)
            let name = counts[base, default: 0] > 1 ? "\(base)-\(shortID(id(item)))" : base
            return ("\(name).\(fileExtension)", item)
        }
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    // MARK: Formatting helpers

    private static func headingDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy, h:mm a"
        return formatter.string(from: date)
    }

    /// The italic line under an Inbox entry's heading: which device recorded it and how long the
    /// clip runs — or, for an entry that was imported as text, simply that. A device and a "0:00"
    /// would be misleading there: nothing was captured.
    private static func provenance(for recording: Recording) -> String {
        recording.isTextOnly
            ? "Imported text"
            : "\(label(for: recording.origin)) · \(Recording.durationLabel(recording.duration))"
    }

    private static func label(for origin: Recording.Origin) -> String {
        switch origin {
        case .watch: return "Apple Watch"
        case .phone: return "iPhone"
        case .pad:   return "iPad"
        }
    }
}
