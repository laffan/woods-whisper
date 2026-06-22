import Foundation
import Combine

/// A lightweight, in-memory, per-session activity log surfaced in the app's Log tab and
/// copyable for debugging. Safe to call from any thread/queue; `@Published` mutations are
/// funnelled to the main thread for SwiftUI.
public final class SessionLog: ObservableObject, @unchecked Sendable {
    public static let shared = SessionLog()

    public enum Category: String, Sendable, CaseIterable {
        case general, model, transfer, transcription, transform, error
    }

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let category: Category
        public let message: String
    }

    @Published public private(set) var entries: [Entry] = []

    private init() {
        log("Session started", category: .general)
    }

    /// Append a log line. Callable from any thread.
    public func log(_ message: String, category: Category = .general) {
        let entry = Entry(date: Date(), category: category, message: message)
        #if DEBUG
        print("[\(category.rawValue)] \(message)")
        #endif
        if Thread.isMainThread {
            entries.append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.entries.append(entry) }
        }
    }

    public func clear() {
        let reset = { self.entries = [] }
        if Thread.isMainThread { reset() } else { DispatchQueue.main.async(execute: reset) }
    }

    /// The whole log as plain text, newest last — for the Copy action.
    public func formattedText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries
            .map { "\(formatter.string(from: $0.date)) [\($0.category.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}

/// Convenience free function so call sites read `wwLog("…", .model)`.
public func wwLog(_ message: String, _ category: SessionLog.Category = .general) {
    SessionLog.shared.log(message, category: category)
}
