import Foundation

/// Logs operation/download progress to the `SessionLog`, throttled to ~5% steps so the log
/// isn't flooded. Thread-safe — the progress callback may fire on any queue.
public final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLogged = -1.0
    private let label: String
    private let category: SessionLog.Category

    public init(label: String, category: SessionLog.Category = .model) {
        self.label = label
        self.category = category
    }

    /// Report a `Foundation.Progress` (e.g. a byte download). Formats counts as data sizes.
    public func report(_ progress: Progress) {
        let detail: String? = progress.totalUnitCount > 0
            ? "\(Self.bytes(progress.completedUnitCount)) / \(Self.bytes(progress.totalUnitCount))"
            : nil
        report(fraction: progress.fractionCompleted, detail: detail)
    }

    /// Report a fraction in [0,1] with an optional preformatted detail string (e.g. "files 3/12").
    public func report(fraction: Double, detail: String? = nil) {
        guard fraction.isFinite else { return }
        lock.lock()
        let crossed = (fraction - lastLogged >= 0.05) || (fraction >= 1.0 && lastLogged < 1.0)
        if crossed { lastLogged = fraction }
        lock.unlock()
        guard crossed else { return }

        let pct = String(format: "%.0f%%", fraction * 100)
        if let detail {
            wwLog("\(label): \(pct) — \(detail)", category)
        } else {
            wwLog("\(label): \(pct)", category)
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
