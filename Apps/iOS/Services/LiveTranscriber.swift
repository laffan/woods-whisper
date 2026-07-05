import Foundation
import AVFoundation
import WoodsWhisperKit

/// Drives the optional "live transcription during recording" display. While a recording is in
/// progress it taps the microphone in parallel with `AudioRecorder`, accumulating the audio as
/// 16 kHz mono `Float` PCM in memory, and re-transcribes the *entire clip so far* on a steady
/// cadence — a full second between attempts.
///
/// Re-processing the whole buffer (rather than appending fixed chunks) means each pass sees
/// complete sentences, so punctuation and casing settle correctly; the trade-off is that the text
/// can shift slightly between updates as later context revises earlier guesses. That's intentional
/// and preferred over chunked output that splits sentences mid-stream.
///
/// This is display-only: the saved recording still comes from `AudioRecorder`'s file. If the
/// capture engine can't start (e.g. the OS won't grant a second input tap), the recording is
/// unaffected — the live panel simply stays empty.
@MainActor
final class LiveTranscriber: ObservableObject {
    /// The best transcript of the clip-so-far, refreshed roughly once a second.
    @Published private(set) var text = ""
    /// True while a transcription pass is running (for a subtle "updating…" affordance).
    @Published private(set) var isProcessing = false

    private let engine = AVAudioEngine()
    private var accumulator: SampleAccumulator?
    private var loop: Task<Void, Never>?
    private var running = false

    /// Begin live capture + transcription using `service` for each pass. No-op if already running.
    func start(using service: TranscriptionService) {
        guard !running else { return }
        text = ""

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        // Parakeet and Whisper both expect 16 kHz mono Float32.
        guard inputFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }

        let accumulator = SampleAccumulator(converter: converter,
                                            inputFormat: inputFormat, targetFormat: targetFormat)
        self.accumulator = accumulator

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            accumulator.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            wwLog("Live transcription: capture engine failed to start (\(error.localizedDescription))", .error)
            input.removeTap(onBus: 0)
            self.accumulator = nil
            return
        }

        running = true
        loop = Task { [weak self] in await self?.runLoop(using: service, accumulator: accumulator) }
    }

    /// Stop capture and end the transcription loop.
    func stop() {
        guard running else { return }
        running = false
        loop?.cancel()
        loop = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        accumulator = nil
    }

    /// Mirror the recorder's pause state so buffered audio stays aligned with the saved clip (a
    /// paused recording isn't capturing, so neither should the live transcript).
    func setPaused(_ paused: Bool) {
        accumulator?.setPaused(paused)
    }

    /// Re-transcribe the whole clip-so-far, then wait a full second before the next pass, until
    /// stopped. Skips a pass while no new audio has arrived since the last one.
    private func runLoop(using service: TranscriptionService, accumulator: SampleAccumulator) async {
        var lastCount = 0
        while running && !Task.isCancelled {
            let snapshot = accumulator.snapshot()
            if snapshot.count > lastCount {
                lastCount = snapshot.count
                isProcessing = true
                do {
                    let result = try await service.transcribe(samples: snapshot)
                    let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { text = trimmed }
                } catch {
                    // Transient — keep the last good text and try again next pass.
                }
                isProcessing = false
            }
            // A full second between attempts (measured from the end of the previous pass).
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

/// Thread-safe accumulator for live capture. Lives off the main actor: the audio tap appends to it
/// on the render thread; the transcription loop snapshots it. Holds the (non-Sendable) converter,
/// which is only ever touched on the audio thread inside `append`.
private final class SampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var paused = false

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        self.converter = converter
        self.inputFormat = inputFormat
        self.targetFormat = targetFormat
    }

    func setPaused(_ p: Bool) { lock.lock(); paused = p; lock.unlock() }

    /// Convert one tapped buffer to 16 kHz mono Float and append it. Dropped while paused.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let isPaused = paused; lock.unlock()
        if isPaused { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let new = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        lock.lock(); samples.append(contentsOf: new); lock.unlock()
    }

    func snapshot() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
}
