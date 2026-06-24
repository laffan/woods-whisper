import Foundation
import Darwin   // fnmatch
import WoodsWhisperKit

#if canImport(MLXLLM)
import MLXLMCommon

/// A `Downloader` (MLXLMCommon) that fetches a HuggingFace model snapshot with a plain
/// **foreground** `URLSession`.
///
/// This replaces MLX's default `#hubDownloader()` (backed by swift-huggingface's `HubClient`),
/// which hung before the first byte on-device even though HuggingFace was reachable (confirmed by
/// the in-app HF probe: HTTP 200 in ~1s, yet zero download progress). We control the whole path
/// here: list the repo's files, filter by the requested glob patterns, and download each over a
/// default `URLSession` with real byte-level progress. Already-complete files are skipped, so an
/// interrupted download resumes.
final class URLSessionHubDownloader: Downloader, @unchecked Sendable {
    static let shared = URLSessionHubDownloader()
    private let host = "https://huggingface.co"

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let revision = revision ?? "main"
        let directory = try Self.modelDirectory(for: id)

        // Honor the requested patterns, but always include config/tokenizer files so the tokenizer
        // loader reads them locally (never re-entering the hub downloader that hung).
        let files = try await listFiles(id: id, revision: revision)
            .filter { Self.matches($0.path, patterns: patterns) || Self.isEssential($0.path) }
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        wwLog("HF download: \(files.count) file(s), "
              + "\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) → \(id)", .model)

        let progress = Progress(totalUnitCount: max(totalBytes, 1))
        var completed: Int64 = 0

        let fetcher = HubFileFetcher()
        defer { fetcher.invalidate() }

        for file in files {
            let destination = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)

            // Resume: skip files already present at the expected size.
            if file.size > 0, Self.fileSize(destination) == file.size {
                completed += file.size
                progress.completedUnitCount = completed
                progressHandler(progress)
                continue
            }

            guard let url = Self.resolveURL(host: host, id: id, revision: revision, path: file.path) else {
                throw URLError(.badURL)
            }
            wwLog("HF download: fetching \(file.path)"
                  + (file.size > 0 ? " (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))" : ""), .model)
            let base = completed
            try await fetcher.fetch(url, to: destination) { written, _ in
                progress.completedUnitCount = base + written
                progressHandler(progress)
            }
            completed = base + (file.size > 0 ? file.size : (Self.fileSize(destination) ?? 0))
            progress.completedUnitCount = completed
            progressHandler(progress)
        }
        return directory
    }

    // MARK: Repo file listing

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    /// List the repo's files (and their sizes) via the HuggingFace tree API.
    private func listFiles(id: String, revision: String) async throws -> [(path: String, size: Int64)] {
        guard let url = URL(string: "\(host)/api/models/\(id)/tree/\(revision)?recursive=true") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HubDownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "model file list")
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return entries.filter { $0.type == "file" }.map { ($0.path, $0.size ?? 0) }
    }

    // MARK: Helpers

    /// Glob-match a repo path against the requested patterns (`*` crosses `/`, matching how
    /// HuggingFace `allow_patterns` works). Empty patterns means "download everything".
    private static func matches(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { fnmatch($0, path, 0) == 0 }
    }

    /// Config/tokenizer files the loader needs locally, always fetched regardless of patterns.
    private static let essentialFiles: Set<String> = [
        "config.json", "generation_config.json",
        "tokenizer.json", "tokenizer_config.json", "tokenizer.model",
        "special_tokens_map.json", "added_tokens.json",
        "vocab.json", "merges.txt", "chat_template.jinja",
    ]

    private static func isEssential(_ path: String) -> Bool {
        essentialFiles.contains((path as NSString).lastPathComponent)
    }

    private static func resolveURL(host: String, id: String, revision: String, path: String) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(host)/\(id)/resolve/\(revision)/\(encoded)")
    }

    private static func modelDirectory(for id: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("huggingface/models/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }
}

enum HubDownloadError: LocalizedError {
    case httpStatus(Int, String)
    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let what): return "HTTP \(code) fetching \(what)"
        }
    }
}

/// Downloads one file with a foreground `URLSession` download task, reporting byte progress via
/// the delegate and moving the result into place. Reused sequentially within a single snapshot.
private final class HubFileFetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL!
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    func fetch(_ url: URL, to destination: URL,
               onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        self.destination = destination
        self.onProgress = onProgress
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let cont = continuation
        continuation = nil
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "file"
            cont?.resume(throwing: HubDownloadError.httpStatus(http.statusCode, name))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            cont?.resume()
        } catch {
            cont?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is handled in didFinishDownloadingTo (which nils the continuation first).
        guard let error else { return }
        let cont = continuation
        continuation = nil
        cont?.resume(throwing: error)
    }
}
#endif
