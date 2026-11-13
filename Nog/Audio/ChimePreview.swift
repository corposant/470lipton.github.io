import AVFoundation

/// Plays a chime once when it's picked in Settings, so people hear what they chose.
/// Mixes with other audio and plays even on silent: you just picked it, so you want to hear it.
@MainActor
enum ChimePreview {
    private static var player: AVAudioPlayer?

    static func play(_ chime: NotificationChime) {
        player?.stop()
        player = nil
        guard let file = chime.fileName,
              let url = Bundle.main.url(forResource: file, withExtension: nil) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            self.player = player
        } catch {
            player = nil
        }
    }
}
