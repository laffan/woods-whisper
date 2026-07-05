import Foundation
import WoodsWhisperKit

/// Internal abstraction over a single speech engine — Parakeet (FluidAudio) or Whisper
/// (WhisperKit). Each backend only knows how to prepare/transcribe its own family of models;
/// `SpeechTranscriptionCoordinator` picks the right one for the active `SpeechModel`.
protocol SpeechModelBackend: AnyObject {
    var isReady: Bool { get async }
    /// Download + load `model`'s weights. `progress` reports download fraction and byte counts.
    func prepare(model: SpeechModel,
                 progress: (@Sendable (DownloadProgress) -> Void)?) async throws
    func transcribe(audioFileAt url: URL) async throws -> TranscriptionResult
    /// Transcribe already-decoded 16 kHz mono `Float` PCM samples (live-transcription path).
    func transcribe(samples: [Float]) async throws -> TranscriptionResult
    /// Drop loaded weights to free memory (e.g. when the user switches engines).
    func unload()
}

/// Routes transcription to the right engine for the user-selected `SpeechModel`, so the rest of
/// the app keeps depending only on `TranscriptionService`. Parakeet and Whisper are different
/// SDKs; this keeps each backend focused while presenting one switchable service.
final class SpeechTranscriptionCoordinator: TranscriptionService {
    private let parakeet = ParakeetTranscriptionService()
    private let whisper = WhisperTranscriptionService()

    private(set) var activeModel: SpeechModel

    init(model: SpeechModel = .default) {
        self.activeModel = model
    }

    private var backend: SpeechModelBackend {
        switch activeModel.engine {
        case .parakeet: return parakeet
        case .whisper:  return whisper
        }
    }

    var isReady: Bool {
        get async { await backend.isReady }
    }

    func setModel(_ model: SpeechModel) async throws {
        guard model != activeModel else { return }
        // Drop the previously-loaded engine's weights so `isReady` reflects the new choice and we
        // don't hold two models in memory. The Download button drives the one-time fetch.
        backend.unload()
        activeModel = model
        wwLog("Speech model switched to \(model.displayName) — download required before use", .model)
    }

    func prepare(progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        try await backend.prepare(model: activeModel, progress: progress)
    }

    func transcribe(audioFileAt url: URL) async throws -> TranscriptionResult {
        try await backend.transcribe(audioFileAt: url)
    }

    func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        try await backend.transcribe(samples: samples)
    }
}
