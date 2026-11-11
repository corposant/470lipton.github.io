import AVFoundation
import Observation

/// Records one voice note into the temporary folder. `stop()` hands it back; the store
/// then moves it next to the nog's file.
@MainActor @Observable
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle, asking, recording
        /// Hit the length limit (or iOS stopped it): save what we have.
        case stoppedItself
        /// Microphone access is off in Settings.
        case denied
        case failed
    }

    private(set) var state: State = .idle
    private(set) var startedAt: Date?
    /// Loudness, 0…1, for the level bar.
    private(set) var level: Double = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    /// Long enough for a ramble, short enough that a forgotten recording doesn't fill the phone.
    static let maxSeconds: TimeInterval = 15 * 60

    func start() async {
        guard state == .idle else { return }
        state = .asking
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        guard state == .asking else { return } // cancelled while asking
        let url = URL.temporaryDirectory.appending(path: VoiceNote.newFileName())
        // Mono AAC: clear speech at about half a megabyte a minute.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maxSeconds) else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            startedAt = .now
            state = .recording
            startMetering()
        } catch {
            print("Nog: couldn't record: \(error)")
            state = .failed
            Self.deactivateSession()
        }
    }

    /// Stops and returns the recording, or nil when there's nothing worth keeping.
    func stop() -> VoiceRecording? {
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        finish()
        let seconds = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
        // Under half a second is a mis-tap, not a thought.
        guard seconds >= 0.5 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return VoiceRecording(url: url, seconds: max(1, Int(seconds.rounded())))
    }

    /// Stops and throws the recording away.
    func cancel() {
        if state == .asking { state = .idle }
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        finish()
    }

    private func finish() {
        meterTask?.cancel()
        meterTask = nil
        level = 0
        recorder = nil
        if state == .recording || state == .stoppedItself { state = .idle }
        Self.deactivateSession()
    }

    private func startMetering() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // -50 dB (quiet room) … 0 dB (shouting) → 0…1
                self.level = Double(max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50)))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Called when the length limit is hit or iOS ends the recording. A stop() we asked for
    // has already cleared `recorder`, so only an unasked-for stop changes the state.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url, self.state == .recording else { return }
            self.meterTask?.cancel()
            self.state = .stoppedItself
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            self.meterTask?.cancel()
            self.state = .stoppedItself
        }
    }
}
