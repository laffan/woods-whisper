import Foundation

/// Lightweight connectivity probes for debugging model downloads. These hit HuggingFace
/// directly with a bounded timeout so a stalled model download can be attributed: if the probe
/// returns a status quickly while the download stays at 0%, the network is fine and the SDK's
/// downloader is the problem; if the probe also hangs/fails, it's reachability to that endpoint.
public enum NetworkProbe {

    /// Perform one request and return a short human description of the outcome (status + timing,
    /// or a connection-error diagnosis). Never throws — it's a diagnostic, not a dependency.
    public static func probe(_ url: URL, method: String = "GET", timeout: TimeInterval = 15) async -> String {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false           // fail fast instead of queuing offline
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse {
                let location = http.value(forHTTPHeaderField: "Location")
                let suffix = location.map { " → \($0)" } ?? ""
                return "HTTP \(http.statusCode) in \(ms)ms (\(data.count) bytes)\(suffix)"
            }
            return "non-HTTP response in \(ms)ms"
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return "failed in \(ms)ms — \(describeDownloadError(error))"
        }
    }

    /// Probe the two endpoints a HuggingFace download touches for `repo` (e.g.
    /// "mlx-community/gemma-3-1b-it-4bit"): the model-info API and the CDN resolve URL for a small
    /// file. Logs each result so a stalled download can be diagnosed from the session log.
    public static func logHuggingFaceReachability(repo: String, file: String = "config.json") async {
        if let api = URL(string: "https://huggingface.co/api/models/\(repo)") {
            wwLog("HF probe → api/models/\(repo)…", .model)
            let result = await probe(api)
            wwLog("HF probe api/models: \(result)", result.contains("failed") ? .error : .model)
        }
        if let resolve = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)") {
            // HEAD on the CDN resolve URL — this is the path the weights themselves stream from.
            let result = await probe(resolve, method: "HEAD")
            wwLog("HF probe resolve/\(file): \(result)", result.contains("failed") ? .error : .model)
        }
    }
}
