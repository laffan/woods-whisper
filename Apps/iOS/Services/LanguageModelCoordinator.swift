import Foundation
import WoodsWhisperKit

/// Routes text transformation to the right backend for the user-selected `LanguageModelChoice`, so
/// the rest of the app keeps depending only on `TextTransformService`. On-device models (Gemma /
/// Qwen / Llama, via MLX) run through `GemmaTransformService`; the online Claude models run through
/// `AnthropicTransformService`. This mirrors `SpeechTranscriptionCoordinator` on the speech side.
///
/// The coordinator owns `activeModel` and forwards `prepare` / `isReady` / `transform` to whichever
/// backend the choice belongs to. Switching to an online model unloads the local weights; switching
/// back to a local model leaves the (one-time) Download flow to re-prepare it.
final class LanguageModelCoordinator: TextTransformService {
    private let onDevice: GemmaTransformService
    private let online: AnthropicTransformService

    private(set) var activeModel: LanguageModelChoice

    init(model: LanguageModelChoice = .default) {
        self.activeModel = model
        // Each backend tracks its own family; seed it with a model it can handle.
        self.onDevice = GemmaTransformService(model: model.isOnline ? .default : model)
        self.online = AnthropicTransformService(model: model.isOnline ? model : .claudeSonnet)
    }

    private var backend: TextTransformService {
        activeModel.isOnline ? online : onDevice
    }

    var isReady: Bool {
        get async { await backend.isReady }
    }

    func setModel(_ model: LanguageModelChoice) async throws {
        guard model != activeModel else { return }
        activeModel = model
        if model.isOnline {
            onDevice.unload()           // free the local weights while the cloud model is active
            try await online.setModel(model)
        } else {
            try await onDevice.setModel(model)
        }
    }

    func prepare(progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        try await backend.prepare(progress: progress)
    }

    /// Delete the active on-device model's downloaded weights (no-op for online models, which have
    /// nothing on disk). Backs Settings' "Remove Download".
    func removeActiveDownload() {
        guard !activeModel.isOnline else { return }
        onDevice.removeDownload()
    }

    @discardableResult
    func transform(
        transcript: String,
        with preset: PromptPreset,
        onToken: (@Sendable (TransformToken) -> Void)? = nil
    ) async throws -> TransformResult {
        try await backend.transform(transcript: transcript, with: preset, onToken: onToken)
    }
}
