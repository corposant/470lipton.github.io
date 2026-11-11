import Foundation

/// A nagging style in one tap: how soon, how often, steady, easing or building,
/// alarm or not, silent or not, and when ignored nogs escalate to alarms.
///
/// Listed gentlest to loudest; pickers show them in this order.
enum NogProfile: String, CaseIterable, Identifiable {
    case hush, teatime, whisper, daily, easing, steady, building, unhinged
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hush: "Hush"
        case .teatime: "Teatime"
        case .whisper: "Whisper"
        case .daily: "Daily"
        case .easing: "Easing"
        case .steady: "Steady"
        case .building: "Building"
        case .unhinged: "Unhinged"
        }
    }

    var summary: String {
        switch self {
        case .hush: "Every 15 min. Silent banner, no sound."
        case .teatime: "4 PM, every other day."
        case .whisper: "Hourly, easing off to daily."
        case .daily: "Once a day, same time."
        case .easing: "8 min, 16, 32… easing off to daily."
        case .steady: "After 15 min, then every 8."
        case .building: "Countdown, then every 30 min, speeding up to 4."
        case .unhinged: "Every 7 min. Rings as an alarm after 3 ignored."
        }
    }

    var systemImage: String {
        switch self {
        case .hush: "speaker.slash.fill"
        case .teatime: "cup.and.saucer.fill"
        case .whisper: "wind"
        case .daily: "sunrise.fill"
        case .easing: "chart.line.downtrend.xyaxis"
        case .steady: "metronome"
        case .building: "chart.line.uptrend.xyaxis"
        case .unhinged: "bolt.fill"
        }
    }

    /// Minutes after capture before the first nog.
    var firstDelayMinutes: Int {
        switch self {
        case .hush: 15
        case .teatime: 0
        case .whisper: 60
        case .daily: 1440
        case .easing: 8
        case .steady: 15
        case .building: 30
        case .unhinged: 2
        }
    }

    var repeatMinutes: Int {
        switch self {
        case .hush: 15
        case .teatime: 2880
        case .whisper: 60
        case .daily: 1440
        case .easing: 8
        case .steady: 8
        case .building: 30
        case .unhinged: 7
        }
    }

    var curve: RepeatCurve {
        switch self {
        case .whisper, .easing: .logarithmic
        case .building: .building
        case .hush, .teatime, .daily, .steady, .unhinged: .steady
        }
    }

    /// nil = follow the global "ring as an alarm after" setting; 0 = never.
    var escalateAfter: Int? {
        switch self {
        case .hush, .teatime, .whisper, .daily: 0
        case .steady, .easing, .building: nil
        case .unhinged: 3
        }
    }

    /// The line under the title on this profile's notifications.
    var bannerLine: String {
        switch self {
        case .hush: "Quiet nog."
        case .teatime: "Tea time."
        case .whisper: "When you're ready."
        case .daily: "Today's nog."
        case .easing: "Easing off."
        case .steady: "Still here."
        case .building: "Getting louder."
        case .unhinged: "Not letting this go."
        }
    }

    /// One step quieter, for a notification's "Gentler" button. nil on profiles that are already quiet.
    var gentler: NogProfile? {
        switch self {
        case .unhinged: .building
        case .building: .steady
        case .steady: .easing
        case .easing: .whisper
        case .hush, .teatime, .whisper, .daily: nil
        }
    }

    /// Nogs once a day or less: their notifications offer "Skip today" instead of "Snooze till 9 AM".
    var skipsDays: Bool { self == .daily || self == .teatime }

    /// No sound and no Time Sensitive break-through, whatever the global settings say.
    var silent: Bool { self == .hush }

    /// Starts at this time of day (minutes after midnight) instead of after a delay.
    var timeOfDay: Int? { self == .teatime ? 16 * 60 : nil }

    /// When a new capture in this profile first reminds you.
    func firstStart(from now: Date, calendar: Calendar = .current) -> Date {
        Self.firstStart(delayMinutes: firstDelayMinutes, timeOfDay: timeOfDay, from: now, calendar: calendar)
    }

    /// The next `timeOfDay` (today if it's still ahead), or `delayMinutes` from now.
    static func firstStart(delayMinutes: Int, timeOfDay: Int?, from now: Date,
                           calendar: Calendar = .current) -> Date {
        guard let timeOfDay,
              let today = calendar.date(bySettingHour: timeOfDay / 60, minute: timeOfDay % 60, second: 0, of: now)
        else { return now.addingTimeInterval(TimeInterval(delayMinutes * 60)) }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

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
        apply(to: Reminder(start: firstStart(from: now)))
    }

    /// The profile a reminder follows, if it matches one exactly (otherwise it's "Custom").
    static func matching(_ reminder: Reminder) -> NogProfile? {
        allCases.first {
            $0.repeatMinutes == reminder.repeatMinutes && $0.curve == reminder.curve
                && $0.escalateAfter == reminder.escalateAfter && $0.silent == reminder.silent
        }
    }

    /// Capture tokens: `!hush`, `!whisper`, `!daily`, `!easing`, `!steady`, `!building`,
    /// `!teatime` (or `!tea`), `!unhinged`, or the first few letters of one (`!unh`, `!hyp`, `!bui`).
    /// `!gentle` still means Whisper; `!tea` is Teatime.
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
    static let aliases: [String: NogProfile] = ["gentle": .whisper, "tea": .teatime]

    /// Profiles you can type in a capture: all of them.
    static let tokenProfiles: [NogProfile] = allCases

    /// Shortest abbreviation `token` accepts, so `!u` or `!e` don't switch profile by accident.
    static let minimumPrefix = 3
}
