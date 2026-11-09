import Foundation

/// A nagging style in one tap: how soon, how often, steady or easing,
/// alarm or not, and when ignored nogs escalate to alarms.
enum NogProfile: String, CaseIterable, Identifiable {
    case whisper, steady, easing, unhinged
    var id: String { rawValue }

    var label: String {
        switch self {
        case .whisper: "Whisper"
        case .steady: "Steady"
        case .easing: "Easing"
        case .unhinged: "Unhinged"
        }
    }

    var summary: String {
        switch self {
        case .whisper: "After an hour, then hourly, easing off to daily. Never rings."
        case .steady: "After 15 min, then every 8 min until done."
        case .easing: "After 8 min, then 16, 32, 64… easing off to daily."
        case .unhinged: "After 2 min, then every 7 min, no let-up. Rings as an alarm after 3 ignored nogs."
        }
    }

    var systemImage: String {
        switch self {
        case .whisper: "wind"
        case .steady: "metronome"
        case .easing: "chart.line.downtrend.xyaxis"
        case .unhinged: "bolt.fill"
        }
    }

    /// Minutes after capture before the first nog.
    var firstDelayMinutes: Int {
        switch self {
        case .whisper: 60
        case .steady: 15
        case .easing: 8
        case .unhinged: 2
        }
    }

    var repeatMinutes: Int {
        switch self {
        case .whisper: 60
        case .steady: 8
        case .easing: 8
        case .unhinged: 7
        }
    }

    var curve: RepeatCurve {
        switch self {
        case .whisper, .easing: .logarithmic
        case .steady, .unhinged: .steady
        }
    }

    /// nil = follow the global "ring as an alarm after" setting; 0 = never.
    var escalateAfter: Int? {
        switch self {
        case .whisper: 0
        case .steady, .easing: nil
        case .unhinged: 3
        }
    }

    /// Applies this profile's rhythm to a reminder, keeping its start time.
    func apply(to reminder: Reminder) -> Reminder {
        var r = reminder
        r.repeatMinutes = repeatMinutes
        r.curve = curve
        r.escalateAfter = escalateAfter
        // "Ring like an alarm" is its own switch: a profile keeps whatever it was.
        return r
    }

    /// A fresh reminder in this profile, starting `firstDelayMinutes` from `now`.
    func reminder(from now: Date = .now) -> Reminder {
        apply(to: Reminder(start: now.addingTimeInterval(TimeInterval(firstDelayMinutes * 60))))
    }

    /// The profile a reminder follows, if it matches one exactly (otherwise it's "Custom").
    static func matching(_ reminder: Reminder) -> NogProfile? {
        allCases.first {
            $0.repeatMinutes == reminder.repeatMinutes && $0.curve == reminder.curve
                && $0.escalateAfter == reminder.escalateAfter
        }
    }

    /// Capture tokens: `!whisper`, `!unhinged`, …
    static func token(_ word: String) -> NogProfile? {
        switch word {
        case "!whisper", "!gentle": .whisper
        case "!unhinged", "!relentless", "!hound": .unhinged
        case "!easing": .easing
        default: nil
        }
    }
}
