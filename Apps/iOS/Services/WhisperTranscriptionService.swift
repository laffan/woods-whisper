import Foundation
import WoodsWhisperKit

#if canImport(WhisperKit)
import WhisperKit
#endif

/// Whisper (CoreML) transcription via the WhisperKit package — the smaller variants
/// (tiny / base / small) for users who prefer Whisper over Parakeet or want a lighter download.
///
/// Mirrors `ParakeetTranscriptionService`: `prepare(model:progress:)` downloads + loads the
/// CoreML weights once (offline afterward), and `transcribe` runs an audio file through the
/// loaded pipeline. WhisperKit handles decoding/resampling from the file path itself, so no
/// manual PCM conversion is needed here.
///
/// One of the engines behind `SpeechTranscriptionCoordinator`. iOS/iPadOS only; on the Watch
/// (no WhisperKit) every method throws `.unsupportedPlatform`.
///
/// ⚠️ WhisperKit's API moves quickly. The version-sensitive lines are marked `(1)/(2)/(3)`; if
/// Xcode flags a mismatch after resolving packages, adjust those.
final class WhisperTranscriptionService: SpeechModelBackend {

    #if canImport(WhisperKit)
    private var kit: WhisperKit?
    #endif

    /// The HuggingFace repo of prebuilt WhisperKit CoreML models.
    private let repo = "argmaxinc/whisperkit-coreml"

    var isReady: Bool {
        get async {
            #if canImport(WhisperKit)
            return kit != nil
            #else
            return false
            #endif
        }
    }

    func unload() {
        #if canImport(WhisperKit)
        kit = nil
        #endif
    }

    func prepare(model: SpeechModel,
                 progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        #if canImport(WhisperKit)
        let variant = model.rawValue                       // (1) e.g. "openai_whisper-base"
        wwLog("Speech model download starting: \(variant)", .model)
        let throttle = ProgressThrottle(label: "Whisper model")
        let stall = DownloadStallMonitor(label: "Whisper model")
        stall.start()
        defer { stall.stop() }
        do {
            // (2) Download this variant's CoreML weights, reporting byte-level progress. Re-running
            // resumes via WhisperKit's cache; loads offline afterward.
            let folder = try await WhisperKit.download(variant: variant, from: repo) { p in
                stall.update(p.fractionCompleted)
                throttle.report(p)
                progress?(DownloadProgress(p))
            }
            wwLog("Whisper weights present — loading + prewarming pipeline…", .model)
            // (3) Load + prewarm the pipeline from the downloaded folder (no further network).
            let config = WhisperKitConfig(model: variant,
                                          modelFolder: folder.path,
                                          prewarm: true,
                                          load: true,
                                          download: false)
            self.kit = try await WhisperKit(config)
            wwLog("Speech model (\(variant)) loaded into memory", .model)
        } catch {
            wwLog("Speech model download failed: \(describeDownloadError(error))", .error)
            throw TranscriptionError.underlying(error)
        }
        #else
        throw TranscriptionError.unsupportedPlatform
        #endif
    }

    func transcribe(audioFileAt url: URL) async throws -> WoodsWhisperKit.TranscriptionResult {
        #if canImport(WhisperKit)
        guard let kit else { throw TranscriptionError.modelsNotPrepared }
        let started = Date()
        do {
            // (1) WhisperKit returns one result per decoded window; join their text.
            let results = try await kit.transcribe(audioPath: url.path)
            let text = results.map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return WoodsWhisperKit.TranscriptionResult(
                text: text,
                detectedLanguage: results.first?.language,
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            throw TranscriptionError.underlying(error)
        }
        #else
        throw TranscriptionError.unsupportedPlatform
        #endif
    }
}
