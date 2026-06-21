import Foundation
import AVFoundation

/// Records microphone audio to an `.m4a` file at 16 kHz mono — the format Parakeet expects,
/// so no resampling is needed before transcription. Works on both watchOS and iOS.
///
/// This is an `@MainActor` observable object so SwiftUI views can bind to recording state.
@MainActor
public final class AudioRecorder: NSObject, ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var currentLevel: Float = 0      // 0...1, for a live meter
    @Published public private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var startDate: Date?

    public var outputURL: URL?

    public override init() { super.init() }

    /// Request microphone permission. Call before `start`.
    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Begin recording into `url`. Returns the URL on success.
    @discardableResult
    public func start(to url: URL) throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw AudioRecorderError.couldNotStart
        }

        self.recorder = recorder
        self.outputURL = url
        self.isRecording = true
        self.startDate = Date()
        startLevelTimer()
        return url
    }

    /// Stop recording. Returns the finished file URL and its duration.
    @discardableResult
    public func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let url = outputURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        stopLevelTimer()
        isRecording = false
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (url, duration)
    }

    private func startLevelTimer() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)        // dBFS, ~ -160...0
                self.currentLevel = Self.normalizedPower(power)
                if let start = self.startDate { self.elapsed = Date().timeIntervalSince(start) }
            }
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        currentLevel = 0
    }

    private static func normalizedPower(_ db: Float) -> Float {
        let minDb: Float = -60
        if db < minDb { return 0 }
        if db >= 0 { return 1 }
        return (db - minDb) / -minDb
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    public nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.isRecording = false }
    }
}

public enum AudioRecorderError: Error {
    case couldNotStart
}
