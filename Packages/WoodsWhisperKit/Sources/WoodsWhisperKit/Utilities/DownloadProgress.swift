import Foundation

/// A download/preparation progress sample passed from the model services up to the UI.
///
/// Carries the 0...1 fraction plus, when the downloader exposes them, the byte counts so the
/// UI can show "1.2 GB / 2.5 GB" and the log can record real progress (not just a percentage
/// that may be stuck at 0% while a single large file downloads).
public struct DownloadProgress: Sendable, Equatable {
    /// Completed fraction in [0, 1].
    public var fractionCompleted: Double
    /// Bytes downloaded so far, if the downloader reports byte-level progress.
    public var completedBytes: Int64?
    /// Total bytes expected, if known.
    public var totalBytes: Int64?
    /// Optional phase note (e.g. "files 3/12", "compiling", "loading weights").
    public var detail: String?

    public init(fractionCompleted: Double,
                completedBytes: Int64? = nil,
                totalBytes: Int64? = nil,
                detail: String? = nil) {
        self.fractionCompleted = fractionCompleted.isFinite ? min(max(fractionCompleted, 0), 1) : 0
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.detail = detail
    }

    /// Build from a `Foundation.Progress`, treating its unit counts as bytes when a total is set.
    public init(_ progress: Foundation.Progress, detail: String? = nil) {
        let total = progress.totalUnitCount
        self.init(fractionCompleted: progress.fractionCompleted,
                  completedBytes: total > 0 ? progress.completedUnitCount : nil,
                  totalBytes: total > 0 ? total : nil,
                  detail: detail)
    }

    /// Convenience for a plain fraction with no byte counts.
    public static func fraction(_ f: Double, detail: String? = nil) -> DownloadProgress {
        DownloadProgress(fractionCompleted: f, detail: detail)
    }

    /// "1.2 GB / 2.5 GB" when byte counts are known, else nil.
    public var byteSummary: String? {
        guard let total = totalBytes, total > 0 else { return nil }
        let done = completedBytes ?? 0
        return "\(Self.bytes(done)) / \(Self.bytes(total))"
    }

    /// A single-line log description: "42% — 1.2 GB / 2.5 GB (files 3/12)".
    public var logLine: String {
        var parts = [String(format: "%.0f%%", fractionCompleted * 100)]
        if let byteSummary { parts.append(byteSummary) }
        if let detail, !detail.isEmpty { parts.append("(\(detail))") }
        return parts.joined(separator: " — ")
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// Watches a long-running download and logs a warning when no forward progress arrives for
/// `interval` seconds. This makes a silently-stalled connection visible in the session log —
/// the symptom being a download that "starts but never gets past 0%, with nothing in the log".
///
/// Call `start()` before the download `await`, `update(_:)` from the progress callback, and
/// `stop()` in a `defer`. Thread-safe; the progress callback may fire on any queue.
public final class DownloadStallMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction = 0.0
    private var lastChange = Date()
    private var warned = false
    private let label: String
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    public init(label: String, interval: TimeInterval = 20) {
        self.label = label
        self.interval = interval
    }

    /// Record the latest fraction; resets the stall timer when progress moves forward.
    public func update(_ fraction: Double) {
        guard fraction.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        if fraction > lastFraction + 0.0001 {
            lastFraction = fraction
            lastChange = Date()
            warned = false
        }
    }

    public func start() {
        lock.lock(); lastChange = Date(); lock.unlock()
        let interval = self.interval
        let label = self.label
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.lock.lock()
                let idle = Date().timeIntervalSince(self.lastChange)
                let frac = self.lastFraction
                let shouldWarn = idle >= interval && !self.warned
                if shouldWarn { self.warned = true }
                self.lock.unlock()
                if shouldWarn {
                    wwLog(String(format: "%@: no progress for %.0fs (stuck at %.0f%%) — slow or stalled connection?",
                                 label, idle, frac * 100), .error)
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
