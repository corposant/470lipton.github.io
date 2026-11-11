import Foundation

/// A recording on a nog. The audio sits next to the item's Markdown file, so it syncs with
/// iCloud Drive and shows in the Files app, named `voice-<uuid>.m4a`. The item's header
/// lists each one with its length: `voice: [voice-6F1C….m4a=42]`.
struct VoiceNote: Hashable {
    var file: String
    /// Length, rounded to the second.
    var seconds: Int

    static let fileExtension = "m4a"

    static func newFileName() -> String { "voice-\(UUID().uuidString).\(fileExtension)" }

    /// Only plain names Nog made itself, so an edited file can't point outside the folder.
    static func isValidFile(_ name: String) -> Bool {
        name.hasPrefix("voice-") && name.hasSuffix(".\(fileExtension)")
            && !name.contains("/") && !name.contains("..") && !name.contains(",") && !name.contains("=")
    }

    /// "Voice nog 8:44 AM": the title of a nog captured with a recording and no words.
    static func captureTitle(_ date: Date) -> String {
        "Voice nog " + date.formatted(date: .omitted, time: .shortened)
    }

    /// "0:42", "12:05"
    var clock: String { Self.clock(TimeInterval(seconds)) }

    static func clock(_ time: TimeInterval) -> String {
        let s = max(0, Int(time.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "42 seconds", "1 minute, 5 seconds": for VoiceOver.
    var spokenLength: String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}

/// A finished recording, still in the temporary folder, waiting to be attached to a nog.
struct VoiceRecording {
    let url: URL
    let seconds: Int
    var file: String { url.lastPathComponent }
}
