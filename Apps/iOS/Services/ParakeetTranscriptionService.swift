import Foundation
import AVFoundation
import WoodsWhisperKit

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Parakeet TDT v3 (CoreML / ANE) transcription via the FluidAudio package.
///
/// Uses `UnifiedAsrManager`, FluidAudio's offline batch API: `loadModels()` downloads the
/// Parakeet "unified offline" CoreML models once (then loads from local cache), and
/// `transcribe(_:)` returns the text for arbitrary-length 16 kHz mono samples — no decoder
/// state to manage. Runs only on iOS/iPadOS; on the Watch the methods throw
/// `.unsupportedPlatform`, so this type compiles everywhere without pulling in the models.
public final class ParakeetTranscriptionService: TranscriptionService {

    #if canImport(FluidAudio)
    private var manager: UnifiedAsrManager?
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
            // Downloads the offline models on first run, then loads from local cache (offline).
            let manager = UnifiedAsrManager()
            try await manager.loadModels()
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
            let text = try await manager.transcribe(samples)
            return TranscriptionResult(
                text: text,
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
