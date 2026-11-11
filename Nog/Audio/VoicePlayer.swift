import AVFoundation
import Observation

/// Plays one voice note at a time, anywhere in the app. Plays out loud even with the
/// ring switch on silent, like Voice Memos: you tapped Play, so you want to hear it.
@MainActor @Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    /// The note playing now.
    private(set) var playing: String?
    /// The note being fetched (from iCloud, it may need to download first).
    private(set) var loading: String?
    /// The last note that couldn't be played.
    private(set) var failed: String?

    @ObservationIgnored private var player: AVAudioPlayer?

    override init() {
        super.init()
        // A call or an alarm cuts in: iOS pauses the player, so stop rather than look stuck.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// How far into the playing note, in seconds.
    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    func toggle(_ note: VoiceNote, store: ItemStore) async {
        if playing == note.file || loading == note.file { return stop() }
        stop()
        failed = nil
        loading = note.file
        let data = await store.voiceNoteData(note.file)
        guard loading == note.file else { return } // tapped something else meanwhile
        loading = nil
        do {
            guard let data else { throw CocoaError(.fileReadNoSuchFile) }
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            self.player = player
            playing = note.file
        } catch {
            print("Nog: couldn't play \(note.file): \(error)")
            failed = note.file
            VoiceRecorder.deactivateSession()
        }
    }

    func stop() {
        loading = nil
        guard player != nil || playing != nil else { return }
        player?.stop()
        player = nil
        playing = nil
        VoiceRecorder.deactivateSession()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stop()
        }
    }
}
