import Foundation
import AVFoundation

/// Records microphone audio to an `.m4a` file at 16 kHz mono — the format Parakeet expects,
/// so no resampling is needed before transcription. Works on both watchOS and iOS.
///
/// This is an `@MainActor` observable object so SwiftUI views can bind to recording state.
@MainActor
public final class AudioRecorder: NSObject, ObservableObject {
    @Published public private(set) var isRecording = false
    /// True while recording is paused (still an active session, just not capturing).
    @Published public private(set) var isPaused = false
    @Published public private(set) var currentLevel: Float = 0      // 0...1, for a live meter
    @Published public private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var startDate: Date?
    /// Accumulated recorded time across pause/resume cycles. `elapsed` is this plus the time
    /// since the most recent resume, so the timer doesn't keep counting while paused.
    private var accumulatedElapsed: TimeInterval = 0

    public var outputURL: URL?

    /// Preferred capture input (port UID) chosen in Settings; `nil` means the system default.
    /// Applied to the audio session at the start of each recording. App-wide, so every recorder
    /// honours the choice without threading it through each call site.
    public static var preferredInputUID: String?

    public override init() { super.init() }

    /// A selectable microphone input (built-in, wired, Bluetooth, …).
    public struct InputOption: Identifiable, Hashable, Sendable {
        public let id: String      // AVAudioSessionPortDescription.uid
        public let name: String    // user-facing port name
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// The microphones currently available to capture from. iOS only (empty elsewhere).
    public static func availableInputs() -> [InputOption] {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // The category must allow recording (and Bluetooth) for the inputs to be enumerable.
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        return (session.availableInputs ?? []).map { InputOption(id: $0.uid, name: $0.portName) }
        #else
        return []
        #endif
    }

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
        #if os(iOS)
        try configureForCapture(session)
        #else
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        #endif
        try session.setActive(true)
        applyPreferredInput(to: session)

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
        self.isPaused = false
        self.accumulatedElapsed = 0
        self.elapsed = 0
        self.startDate = Date()
        startLevelTimer()
        return url
    }

    /// Pause an in-progress recording. The file stays open; `resume()` continues into it.
    public func pause() {
        guard let recorder, isRecording, !isPaused else { return }
        recorder.pause()
        if let start = startDate { accumulatedElapsed += Date().timeIntervalSince(start) }
        startDate = nil
        // Settle `elapsed` on the exact pause instant rather than leaving it wherever the 0.1s
        // timer last left it — the paused counter is a frozen number, on screen and on the Lock
        // Screen, so it shouldn't be up to a tenth of a second short.
        elapsed = accumulatedElapsed
        isPaused = true
        currentLevel = 0
        stopLevelTimer()
    }

    /// Resume a paused recording, appending to the same file.
    ///
    /// The session is made active again first: a pause that ran on behind a locked screen may have
    /// had it taken away (another app's audio, the system suspending the app), and a recorder asked
    /// to record on an inactive session just answers `false`.
    public func resume() {
        guard let recorder, isRecording, isPaused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            wwLog("Couldn't reactivate the audio session to continue: \(error.localizedDescription)",
                  .error)
        }
        guard recorder.record() else {
            wwLog("The recorder refused to continue — the recording is still paused", .error)
            return
        }
        startDate = Date()
        isPaused = false
        startLevelTimer()
    }

    /// Stop recording. Returns the finished file URL and its duration.
    @discardableResult
    public func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let url = outputURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        stopLevelTimer()
        isRecording = false
        isPaused = false
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (url, duration)
    }

    #if os(iOS)
    /// Set the session up to record **alongside** whatever else is playing, rather than instead of
    /// it — music or a podcast in your Bluetooth headphones carries on, at full volume, while you
    /// dictate into the phone's own microphone.
    ///
    /// Three things make that work, and one thing used to stop it:
    /// • **`mixWithOthers`**, so starting a clip doesn't interrupt the other app. (It replaces
    ///   `duckOthers`, which kept it playing but turned it down for the length of every clip.)
    /// • **`allowBluetoothA2DP`**, so headphones stay on the high-quality, output-only profile
    ///   they're playing on. A2DP carries no microphone, so the input is the built-in one (or a
    ///   wired one) — exactly the "dictate into the phone, listen in the headphones" case.
    /// • **`defaultToSpeaker`**, so with no headphones at all, audio already coming out of the
    ///   speaker isn't moved to the earpiece the moment recording starts.
    /// • What stopped it was `allowBluetooth` (the hands-free profile). With it, the system
    ///   prefers the headset's own microphone, which switches the headphones to call audio: the
    ///   music drops to telephone quality or stops. So it's only asked for when the microphone
    ///   picked in Settings *is* a Bluetooth headset's — then there's no way round the switch,
    ///   since a headset can't play A2DP and record at once.
    private func configureForCapture(_ session: AVAudioSession) throws {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP,
                                                       .defaultToSpeaker]
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        // A headset's microphone is only listed while the category allows the hands-free
        // profile, so a chosen input that isn't here now is one of those.
        guard let uid = Self.preferredInputUID,
              !(session.availableInputs ?? []).contains(where: { $0.uid == uid }) else { return }
        options.insert(.allowBluetooth)
        try session.setCategory(.playAndRecord, mode: .default, options: options)
    }
    #endif

    /// Route capture to the user-selected microphone, if one is chosen and present.
    private func applyPreferredInput(to session: AVAudioSession) {
        #if os(iOS)
        guard let uid = Self.preferredInputUID,
              let input = session.availableInputs?.first(where: { $0.uid == uid }) else { return }
        try? session.setPreferredInput(input)
        #endif
    }

    private func startLevelTimer() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)        // dBFS, ~ -160...0
                self.currentLevel = Self.normalizedPower(power)
                if let start = self.startDate {
                    self.elapsed = self.accumulatedElapsed + Date().timeIntervalSince(start)
                }
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
