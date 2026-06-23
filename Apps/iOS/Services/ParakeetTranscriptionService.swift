import Foundation
import AVFoundation
import WoodsWhisperKit

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Parakeet TDT v3 (CoreML / ANE) transcription via the FluidAudio package.
///
/// Uses the mature `AsrModels` + `AsrManager` API with the multilingual
/// `parakeet-tdt-0.6b-v3` CoreML models (the same path most shipping FluidAudio apps use,
/// and more reliable than the newer "unified offline" int8 models). `downloadAndLoad`
/// fetches the models once; afterwards everything is offline. Batch transcription needs a
/// `TdtDecoderState`, created per call via `TdtDecoderState.make(decoderLayers:)`.
///
/// Runs only on iOS/iPadOS; on the Watch the methods throw `.unsupportedPlatform`, so this
/// type compiles everywhere without pulling in the models.
public final class ParakeetTranscriptionService: TranscriptionService {

    #if canImport(FluidAudio)
    private var manager: AsrManager?
    #endif

    public init() {}

    public var isReady: Bool {
        get async {
            #if canImport(FluidAudio)
            return manager != nil
            #else
            return false
            #endif
        }
    }

    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        #if canImport(FluidAudio)
        do {
            // Downloads on first run (re-running resumes already-fetched files), then loads
            // from local cache (offline). Progress reports file-count phases.
            let throttle = ProgressThrottle(label: "Speech model")
            let models = try await AsrModels.downloadAndLoad(version: .v3) { dp in
                throttle.report(fraction: dp.fractionCompleted, detail: Self.detail(for: dp.phase))
                progress?(dp.fractionCompleted)
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
        } catch {
            throw TranscriptionError.underlying(error)
        }
        #else
        throw TranscriptionError.unsupportedPlatform
        #endif
    }

    #if canImport(FluidAudio)
    private static func detail(for phase: DownloadUtils.DownloadPhase) -> String? {
        switch phase {
        case .listing: return "listing files"
        case .downloading(let completed, let total): return total > 0 ? "files \(completed)/\(total)" : "downloading"
        case .compiling(let name): return name.isEmpty ? "compiling" : "compiling \(name)"
        @unknown default: return nil
        }
    }
    #endif

    public func transcribe(audioFileAt url: URL) async throws -> TranscriptionResult {
        #if canImport(FluidAudio)
        guard let manager else { throw TranscriptionError.modelsNotPrepared }
        let started = Date()
        let samples = try Self.readMonoSamples(from: url)        // [Float] @16 kHz
        do {
            // Fresh decoder state per batch transcription (mirrors FluidAudio's own usage).
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &state)
            return TranscriptionResult(
                text: result.text,
                detectedLanguage: nil,
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            throw TranscriptionError.underlying(error)
        }
        #else
        throw TranscriptionError.unsupportedPlatform
        #endif
    }

    /// Decode an audio file to mono 16 kHz `Float` PCM samples (Parakeet's expected input).
    /// We already record at 16 kHz mono, so this is usually a straight read.
    static func readMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: false)!

        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw TranscriptionError.audioReadFailed(url)
        }

        let sourceFrameCount = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: sourceFrameCount) else {
            throw TranscriptionError.audioReadFailed(url)
        }
        try file.read(into: inputBuffer)

        let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: outCapacity) else {
            throw TranscriptionError.audioReadFailed(url)
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw TranscriptionError.underlying(conversionError) }

        guard let channel = outputBuffer.floatChannelData?[0] else {
            throw TranscriptionError.audioReadFailed(url)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}
