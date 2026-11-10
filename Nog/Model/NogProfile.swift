import Foundation

/// A nagging style in one tap: how soon, how often, steady, easing or building,
/// alarm or not, silent or not, and when ignored nogs escalate to alarms.
///
/// Listed gentlest to loudest; pickers show them in this order.
enum NogProfile: String, CaseIterable, Identifiable {
    case hush, whisper, daily, easing, steady, building, hyperfocus, unhinged
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hush: "Hush"
        case .whisper: "Whisper"
        case .daily: "Daily"
        case .easing: "Easing"
        case .steady: "Steady"
        case .building: "Building"
        case .hyperfocus: "Hyperfocus"
        case .unhinged: "Unhinged"
        }
    }

    var summary: String {
        switch self {
        case .hush: "After 15 min, then every 15 min. Always silent, just a banner. Never rings."
        case .whisper: "After an hour, then hourly, easing off to daily. Never rings."
        case .daily: "Once a day at the same time until done. Never rings."
        case .easing: "After 8 min, then 16, 32, 64… easing off to daily."
        case .steady: "After 15 min, then every 8 min until done."
        case .building: "Heads-up 15, 5 and 1 min before. Then every 30, 15, 8, and every 4 min until done."
        case .hyperfocus: "After 5 min, then every 5 min. Rings as an alarm after 1 ignored nog."
        case .unhinged: "After 2 min, then every 7 min, no let-up. Rings as an alarm after 3 ignored nogs."
        }
    }

    var systemImage: String {
        switch self {
        case .hush: "speaker.slash.fill"
        case .whisper: "wind"
        case .daily: "sunrise.fill"
        case .easing: "chart.line.downtrend.xyaxis"
        case .steady: "metronome"
        case .building: "chart.line.uptrend.xyaxis"
        case .hyperfocus: "scope"
        case .unhinged: "bolt.fill"
        }
    }

    /// Minutes after capture before the first nog.
    var firstDelayMinutes: Int {
        switch self {
        case .hush: 15
        case .whisper: 60
        case .daily: 1440
        case .easing: 8
        case .steady: 15
        case .building: 30
        case .hyperfocus: 5
        case .unhinged: 2
        }
    }

    var repeatMinutes: Int {
        switch self {
        case .hush: 15
        case .whisper: 60
        case .daily: 1440
        case .easing: 8
        case .steady: 8
        case .building: 30
        case .hyperfocus: 5
        case .unhinged: 7
        }
    }

    var curve: RepeatCurve {
        switch self {
        case .whisper, .easing: .logarithmic
        case .building: .building
        case .hush, .daily, .steady, .hyperfocus, .unhinged: .steady
        }
    }

    /// nil = follow the global "ring as an alarm after" setting; 0 = never.
    var escalateAfter: Int? {
        switch self {
        case .hush, .whisper, .daily: 0
        case .steady, .easing, .building: nil
        case .hyperfocus: 1
        case .unhinged: 3
        }
    }

    /// No sound and no Time Sensitive break-through, whatever the global settings say.
    var silent: Bool { self == .hush }

    /// Applies this profile's rhythm to a reminder, keeping its start time.
    func apply(to reminder: Reminder) -> Reminder {
        var r = reminder
        r.repeatMinutes = repeatMinutes
        r.curve = curve
        r.escalateAfter = escalateAfter
        r.silent = silent
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
                && $0.escalateAfter == reminder.escalateAfter && $0.silent == reminder.silent
        }
    }

    /// Capture tokens: `!hush`, `!whisper`, `!daily`, `!easing`, `!steady`, `!building`,
    /// `!hyperfocus`, `!unhinged`, or the first few letters of one (`!unh`, `!hyp`, `!bui`).
    /// `!gentle` still means Whisper, and `!break` means Hyperfocus.
    static func token(_ word: String) -> NogProfile? {
        let word = word.lowercased()
        guard word.hasPrefix("!") else { return nil }
        let name = word.dropFirst()
        if let alias = aliases[String(name)] { return alias }
        guard name.count >= minimumPrefix, name.allSatisfy(\.isLetter) else { return nil }
        let matches = tokenProfiles.filter { $0.rawValue.hasPrefix(name) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Other words that pick a profile.
    static let aliases: [String: NogProfile] = ["gentle": .whisper, "break": .hyperfocus]

    /// Profiles you can type in a capture: all of them.
    static let tokenProfiles: [NogProfile] = allCases

    /// Shortest abbreviation `token` accepts, so `!u` or `!e` don't switch profile by accident.
    static let minimumPrefix = 3
}
