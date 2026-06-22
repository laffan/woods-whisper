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

    public func report(_ progress: Progress) {
        report(fraction: progress.fractionCompleted,
               completed: progress.completedUnitCount,
               total: progress.totalUnitCount)
    }

    public func report(fraction: Double, completed: Int64 = 0, total: Int64 = 0) {
        lock.lock()
        let crossed = (fraction - lastLogged >= 0.05) || (fraction >= 1.0 && lastLogged < 1.0)
        if crossed { lastLogged = fraction }
        lock.unlock()
        guard crossed, fraction.isFinite else { return }

        if total > 0 {
            wwLog(String(format: "%@: %.0f%% (%lld/%lld)", label, fraction * 100, completed, total), category)
        } else {
            wwLog(String(format: "%@: %.0f%%", label, fraction * 100), category)
        }
    }
}
