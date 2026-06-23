import Foundation

/// Abstracts on-device speech-to-text so the UI layer doesn't depend on a specific engine
/// (FluidAudio/Parakeet or WhisperKit/Whisper) directly, and so the Watch target (which never
/// transcribes) can compile without the ASR dependencies.
public protocol TranscriptionService: AnyObject {
    /// Whether the underlying model files are present locally and ready to use.
    var isReady: Bool { get async }

    /// Which speech model is currently selected.
    var activeModel: SpeechModel { get }

    /// Switch the active speech model. Does not download — it only selects the model and drops
    /// any loaded weights, so `isReady` becomes false until `prepare` is called for the new one.
    func setModel(_ model: SpeechModel) async throws

    /// Download/prepare model assets. Must be called once during initial (online) setup.
    /// After this completes, transcription works fully offline. Re-running resumes any
    /// partially-downloaded assets. `progress` reports download fraction and byte counts.
    func prepare(progress: (@Sendable (DownloadProgress) -> Void)?) async throws

    /// Transcribe an audio file at `url` to text.
    func transcribe(audioFileAt url: URL) async throws -> TranscriptionResult
}

/// Selectable on-device speech-to-text models. Parakeet (the default) runs via FluidAudio; the
/// smaller Whisper variants run via WhisperKit for users who prefer Whisper or want a lighter
/// download. The `rawValue` doubles as each engine's download identifier.
public enum SpeechModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case parakeetV3 = "parakeet-tdt-0.6b-v3"
    case whisperTiny = "openai_whisper-tiny"
    case whisperBase = "openai_whisper-base"
    case whisperSmall = "openai_whisper-small"

    public var id: String { rawValue }

    /// The SDK that backs this model.
    public enum Engine: Sendable { case parakeet, whisper }

    public var engine: Engine {
        switch self {
        case .parakeetV3: return .parakeet
        case .whisperTiny, .whisperBase, .whisperSmall: return .whisper
        }
    }

    public var displayName: String {
        switch self {
        case .parakeetV3:   return "Parakeet TDT v3 (default)"
        case .whisperTiny:  return "Whisper Tiny (smallest)"
        case .whisperBase:  return "Whisper Base"
        case .whisperSmall: return "Whisper Small"
        }
    }

    /// Rough download size advisory, surfaced in Settings.
    public var approxDownloadNote: String {
        switch self {
        case .parakeetV3:   return "~600 MB · most accurate, multilingual"
        case .whisperTiny:  return "~75 MB · fastest, lower accuracy"
        case .whisperBase:  return "~145 MB"
        case .whisperSmall: return "~480 MB · best Whisper accuracy here"
        }
    }

    public static let `default`: SpeechModel = .parakeetV3
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
