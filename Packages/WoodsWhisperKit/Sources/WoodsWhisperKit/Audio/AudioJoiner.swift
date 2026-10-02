import Foundation
import AVFoundation

/// Joins audio files end to end into one — what **Continue Recording** does to the clip it adds to,
/// so the recording really is longer afterwards rather than a second clip filed beside the first.
///
/// The result is written the way `AudioRecorder` writes a capture (AAC in an `.m4a`, 16 kHz mono),
/// so a continued recording is indistinguishable from one that was never stopped: it plays, shares
/// and transcribes like any other. A source in another format — an audio file shared into the app,
/// at 44.1 kHz stereo — is converted on the way in.
public enum AudioJoiner {
    /// The capture format, as `AudioRecorder` sets it up.
    public static let sampleRate: Double = 16_000

    /// Write `sources`, one after another, into a new file at `destination`. Returns the length of
    /// the joined audio in seconds. Nothing is deleted: the sources are the caller's to tidy away
    /// once the join has worked.
    public static func join(_ sources: [URL], into destination: URL) throws -> TimeInterval {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        var frames: AVAudioFramePosition = 0
        do {
            // Scoped so the file is closed — and its header finished — before anyone reads it.
            let output = try AVAudioFile(forWriting: destination, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            for source in sources {
                let input = try AVAudioFile(forReading: source)
                frames += try append(input, to: output)
            }
        }
        return Double(frames) / sampleRate
    }

    /// Copy the whole of `input` onto the end of `output`, converting if the two differ. Returns
    /// the number of frames written.
    private static func append(_ input: AVAudioFile, to output: AVAudioFile) throws -> AVAudioFramePosition {
        let from = input.processingFormat
        let to = output.processingFormat
        let chunk: AVAudioFrameCount = 16_384
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: chunk) else {
            throw AudioJoinerError.couldNotAllocate
        }
        var written: AVAudioFramePosition = 0

        let sameFormat = from.sampleRate == to.sampleRate
            && from.channelCount == to.channelCount
            && from.commonFormat == to.commonFormat
            && from.isInterleaved == to.isInterleaved
        if sameFormat {
            while input.framePosition < input.length {
                try input.read(into: readBuffer, frameCount: chunk)
                guard readBuffer.frameLength > 0 else { break }
                try output.write(from: readBuffer)
                written += AVAudioFramePosition(readBuffer.frameLength)
            }
            return written
        }

        guard let converter = AVAudioConverter(from: from, to: to),
              let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: to,
                frameCapacity: AVAudioFrameCount(Double(chunk) * to.sampleRate / from.sampleRate) + 1_024)
        else { throw AudioJoinerError.couldNotConvert }

        var drained = false
        while true {
            convertedBuffer.frameLength = 0
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
                guard !drained, input.framePosition < input.length else {
                    drained = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: readBuffer, frameCount: chunk)
                } catch {
                    readError = error
                    drained = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard readBuffer.frameLength > 0 else {
                    drained = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return readBuffer
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if convertedBuffer.frameLength > 0 {
                try output.write(from: convertedBuffer)
                written += AVAudioFramePosition(convertedBuffer.frameLength)
            }
            if status == .endOfStream || status == .error { break }
        }
        return written
    }
}

public enum AudioJoinerError: LocalizedError {
    case couldNotAllocate
    case couldNotConvert

    public var errorDescription: String? {
        switch self {
        case .couldNotAllocate: return "Couldn't set aside memory to join the audio."
        case .couldNotConvert:  return "Couldn't convert the audio to join it."
        }
    }
}
