import Foundation
import Darwin   // fnmatch (used by URLSessionHubDownloader below)
import WoodsWhisperKit

#if canImport(MLXLLM)
import MLXLLM          // LLMModelFactory + GenerateParameters
import MLXLMCommon     // ModelContainer, ModelConfiguration, ChatSession, Downloader
import MLXHuggingFace  // #huggingFaceTokenizerLoader() macro
import HuggingFace     // referenced by the tokenizer-loader macro expansion
import Tokenizers      // AutoTokenizer, referenced by the tokenizer-loader macro expansion
#endif

/// Streaming guard that suppresses everything from the first occurrence of any stop sequence
/// onward, and holds back a trailing fragment that could be the *start* of one — so a chat model's
/// turn-end marker (e.g. `<end_of_turn>`, `<|im_end|>`, `<|eot_id|>`) halts generation cleanly
/// instead of being echoed and repeated. Pure value type, unit-testable, no MLX dependency.
struct StopSequenceFilter {
    let stops: [String]
    private(set) var isStopped = false
    private var pending = ""

    init(stops: [String]) { self.stops = stops.filter { !$0.isEmpty } }

    /// Append a streamed chunk; returns the text that is now safe to emit.
    mutating func consume(_ chunk: String) -> String {
        guard !isStopped else { return "" }
        guard !stops.isEmpty else { return chunk }      // nothing to filter
        pending += chunk
        if let cut = earliestStop(in: pending) {       // a full marker is present → emit up to it and stop
            let head = String(pending[..<cut])
            pending = ""
            isStopped = true
            return head
        }
        // Hold back the longest suffix that could be the beginning of a stop sequence.
        let hold = maxTrailingPartial(in: pending)
        let safeEnd = pending.index(pending.endIndex, offsetBy: -hold)
        let emit = String(pending[..<safeEnd])
        pending = String(pending[safeEnd...])
        return emit
    }

    /// Flush any held-back text once the stream ends without hitting a stop sequence.
    mutating func flush() -> String {
        guard !isStopped else { return "" }
        defer { pending = "" }
        return pending
    }

    private func earliestStop(in text: String) -> String.Index? {
        var earliest: String.Index?
        for stop in stops {
            if let r = text.range(of: stop), earliest == nil || r.lowerBound < earliest! {
                earliest = r.lowerBound
            }
        }
        return earliest
    }

    /// Length of the longest suffix of `text` that is a (strict) prefix of some stop sequence.
    private func maxTrailingPartial(in text: String) -> Int {
        var maxLen = 0
        for stop in stops {
            var k = min(stop.count - 1, text.count)
            while k > maxLen {
                if text.hasSuffix(String(stop.prefix(k))) { maxLen = k; break }
                k -= 1
            }
        }
        return maxLen
    }
}

/// On-device text transformation via MLX Swift (Qwen3 / Llama 3.2 / Gemma 3). iOS/iPadOS only.
///
/// Loads the model with `LLMModelFactory.shared.loadContainer`, supplying our own
/// `URLSessionHubDownloader` for the HF download (the stock hub downloader hung on-device), and
/// generates via `ChatSession.streamResponse`. On platforms without MLX (the Watch) every method
/// throws `.unsupportedPlatform`, so the type compiles everywhere and the Watch target links
/// without the LLM dependency.
///
/// (Named `GemmaTransformService` for historical reasons; it now drives whichever
/// `LanguageModelChoice` is selected, not only Gemma.)
public final class GemmaTransformService: TextTransformService {

    public private(set) var activeModel: LanguageModelChoice

    #if canImport(MLXLLM)
    private var container: ModelContainer?
    #endif

    public init(model: LanguageModelChoice = .default) {
        self.activeModel = model
    }

    public var isReady: Bool {
        get async {
            #if canImport(MLXLLM)
            return container != nil
            #else
            return false
            #endif
        }
    }

    /// True if this model's weights are already on disk from a previous session (so `prepare` can
    /// load from cache — even offline — instead of re-downloading). iOS/iPadOS only.
    public var isDownloaded: Bool {
        #if canImport(MLXLLM)
        return URLSessionHubDownloader.hasUsableSnapshot(for: activeModel.rawValue)
        #else
        return false
        #endif
    }

    public func setModel(_ model: LanguageModelChoice) async throws {
        guard model != activeModel else { return }
        activeModel = model
        #if canImport(MLXLLM)
        // Just switch — drop the loaded weights so `isReady` is false until `prepare` is called
        // for the new model. The UI's Download button drives the (one-time, online) fetch.
        container = nil
        wwLog("Language model switched to \(model.displayName) — download required before use", .model)
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }

    public func prepare(progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        #if canImport(MLXLLM)
        // Downloads weights on first run (re-running resumes via the HF cache), then loads from
        // the local cache (offline). `progressHandler` streams a `Foundation.Progress`.
        let configuration = ModelConfiguration(id: activeModel.rawValue)
        let repo = activeModel.rawValue
        wwLog("Language model download starting: \(repo)", .model)

        // Diagnostic: probe HuggingFace directly, concurrently, so a future stall can be attributed
        // (HTTP 200 here + no download progress ⇒ the SDK downloader, not the network). Independent
        // of the download and cancelled when prepare ends.
        let probe = Task.detached(priority: .utility) {
            await NetworkProbe.logHuggingFaceReachability(repo: repo)
        }
        defer { probe.cancel() }

        let throttle = ProgressThrottle(label: "Gemma weights")
        let stall = DownloadStallMonitor(label: "Gemma weights")
        stall.start()
        defer { stall.stop() }
        do {
            // (1) Download with our own foreground-URLSession Downloader instead of MLX's default
            // `#hubDownloader()` (swift-huggingface `HubClient`), which hung before the first byte.
            // (2) Tokenizer still loads from the downloaded files via the HF tokenizer-loader macro.
            container = try await LLMModelFactory.shared.loadContainer(
                from: URLSessionHubDownloader.shared,
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { p in
                    stall.update(p.fractionCompleted)
                    throttle.report(p)
                    progress?(DownloadProgress(p))
                }
            )
            wwLog("Language model weights loaded into memory", .model)
        } catch {
            // Surface the real cause — a wrapped URLError reads as a generic "operation couldn't
            // be completed", which is exactly the unhelpful output the log was missing.
            wwLog("Language model download failed: \(describeDownloadError(error))", .error)
            throw TextTransformError.underlying(error)
        }
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }

    @discardableResult
    public func transform(
        transcript: String,
        with preset: PromptPreset,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        #if canImport(MLXLLM)
        guard let container else { throw TextTransformError.modelNotPrepared }
        let userPrompt = preset.render(with: transcript)

        let params = GenerateParameters(maxTokens: preset.maxTokens,
                                        temperature: Float(preset.temperature))
        // A fresh session per run: the system prompt is the instructions, and we stream tokens.
        let session = ChatSession(container,
                                  instructions: preset.systemPrompt,
                                  generateParameters: params)
        // Halt at the model's turn-end marker. Without this, some chat models (notably Gemma with
        // `<end_of_turn>`) keep emitting the marker after the real answer and run away until the
        // token cap — or the app — gives out. The filter also strips the marker from the output.
        var filter = StopSequenceFilter(stops: activeModel.stopSequences)
        do {
            var output = ""
            for try await chunk in session.streamResponse(to: userPrompt) {
                let safe = filter.consume(chunk)
                if !safe.isEmpty {
                    output += safe
                    onToken?(safe)
                }
                if filter.isStopped { break }   // turn ended — stop generating
            }
            let tail = filter.flush()
            if !tail.isEmpty { output += tail; onToken?(tail) }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TextTransformError.underlying(error)
        }
        #else
        throw TextTransformError.unsupportedPlatform
        #endif
    }
}

#if canImport(MLXLLM)

/// A `Downloader` (MLXLMCommon) that fetches a HuggingFace model snapshot with a plain
/// **foreground** `URLSession`.
///
/// This replaces MLX's default `#hubDownloader()` (backed by swift-huggingface's `HubClient`),
/// which hung before the first byte on-device even though HuggingFace was reachable (confirmed by
/// the in-app HF probe: HTTP 200 in ~1s, yet zero download progress). We control the whole path
/// here: list the repo's files, filter by the requested glob patterns, and download each over a
/// default `URLSession` with real byte-level progress. Already-complete files are skipped, so an
/// interrupted download resumes.
///
/// Lives in this file (rather than its own) so it's part of the existing target without needing a
/// fresh `xcodegen generate` to pick up a new source file.
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
        let files: [(path: String, size: Int64)]
        do {
            files = try await listFiles(id: id, revision: revision)
                .filter { Self.matches($0.path, patterns: patterns) || Self.isEssential($0.path) }
        } catch {
            // Offline (or HuggingFace unreachable) but the snapshot is already on disk from a prior
            // session: load it from cache instead of failing. This is what makes a downloaded model
            // come back ready at launch with no network — the "works offline afterward" promise.
            if Self.hasUsableSnapshot(at: directory) {
                wwLog("HF download: listing unavailable (\(describeDownloadError(error))) — using cached snapshot for \(id)", .model)
                return directory
            }
            throw error
        }
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

    // MARK: Cached-snapshot detection

    /// Whether `id`'s download directory holds a usable snapshot (weights + config + tokenizer).
    static func hasUsableSnapshot(for id: String) -> Bool {
        guard let dir = try? modelDirectory(for: id) else { return false }
        return hasUsableSnapshot(at: dir)
    }

    /// A snapshot is usable once it has model weights, a `config.json`, and a tokenizer file. We
    /// only mark a model downloaded after a fully successful `prepare`, so this is a sanity check
    /// for the offline-load path, not a guarantee of completeness on its own.
    static func hasUsableSnapshot(at directory: URL) -> Bool {
        guard let names = try? FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map({ $0.lastPathComponent }) else { return false }
        let lower = Set(names.map { $0.lowercased() })
        let hasWeights = lower.contains { $0.hasSuffix(".safetensors") }
        let hasConfig = lower.contains("config.json")
        let hasTokenizer = lower.contains("tokenizer.json") || lower.contains("tokenizer.model")
        return hasWeights && hasConfig && hasTokenizer
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
