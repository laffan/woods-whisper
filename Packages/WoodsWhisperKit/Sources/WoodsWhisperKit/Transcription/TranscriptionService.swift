import Foundation

/// Abstracts on-device speech-to-text so the UI layer doesn't depend on FluidAudio directly,
/// and so the Watch target (which never transcribes) can compile without the ASR dependency.
public protocol TranscriptionService: AnyObject {
    /// Whether the underlying model files are present locally and ready to use.
    var isReady: Bool { get async }

    /// Download/prepare model assets. Must be called once during initial (online) setup.
    /// After this completes, transcription works fully offline. Re-running resumes any
    /// partially-downloaded assets. `progress` reports download fraction and byte counts.
    func prepare(progress: (@Sendable (DownloadProgress) -> Void)?) async throws

    /// Transcribe an audio file at `url` to text.
    func transcribe(audioFileAt url: URL) async throws -> TranscriptionResult
}

public struct TranscriptionResult: Sendable {
    public var text: String
    public var detectedLanguage: String?
    public var duration: TimeInterval
    public init(text: String, detectedLanguage: String? = nil, duration: TimeInterval = 0) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.duration = duration
    }
}

public enum TranscriptionError: Error, LocalizedError {
    case modelsNotPrepared
    case unsupportedPlatform
    case audioReadFailed(URL)
    case underlying(Error)

    public var errorDescription: String? {
        switch self {
        case .modelsNotPrepared:
            return "Speech model isn't downloaded yet. Complete setup while online once."
        case .unsupportedPlatform:
            return "Transcription runs on iPhone/iPad, not on this device."
        case .audioReadFailed(let url):
            return "Couldn't read audio at \(url.lastPathComponent)."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}
