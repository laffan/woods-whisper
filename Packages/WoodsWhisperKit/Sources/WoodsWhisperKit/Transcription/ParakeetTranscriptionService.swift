import Foundation
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Parakeet TDT v3 (CoreML / ANE) transcription via the FluidAudio package.
///
/// Runs only on iOS/iPadOS. On platforms without FluidAudio (the Watch) the methods throw
/// `.unsupportedPlatform`, so the type still compiles everywhere and the Watch target links
/// cleanly without pulling in the ASR models.
///
/// NOTE: FluidAudio's surface evolves between releases. The calls below target the documented
/// `AsrModels` / `AsrManager` API. Verify names against the version Xcode resolves and adjust
/// the three marked lines if needed — the rest of the app depends only on `TranscriptionService`.
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

    public func prepare() async throws {
        #if canImport(FluidAudio)
        do {
            // (1) Downloads on first run, then loads from local cache thereafter (offline).
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)   // (2)
            self.manager = manager
        } catch {
            throw TranscriptionError.underlying(error)
        }
        #else
        throw TranscriptionError.unsupportedPlatform
        #endif
    }

    public func transcribe(audioFileAt url: URL) async throws -> TranscriptionResult {
        #if canImport(FluidAudio)
        guard let manager else { throw TranscriptionError.modelsNotPrepared }
        let started = Date()
        let samples = try Self.readMonoSamples(from: url)        // [Float] @16 kHz
        do {
            let result = try await manager.transcribe(samples, source: .microphone)   // (3)
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
