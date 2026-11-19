import Foundation

/// A nagging style in one tap: how soon, how often, steady, easing or building,
/// alarm or not, silent or not, and when ignored nogs escalate to alarms.
///
/// Listed gentlest to loudest; pickers show them in this order.
enum NogProfile: String, CaseIterable, Identifiable {
    case hush, whisper, balanced, easing, steady, building, nagging, unhinged
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hush: "Hush"
        case .whisper: "Whisper"
        case .balanced: "Balanced"
        case .easing: "Easing"
        case .steady: "Steady"
        case .building: "Building"
        case .nagging: "Nagging"
        case .unhinged: "Unhinged"
        }
    }

    var summary: String {
        switch self {
        case .hush: "Every 15 min. Silent banner, no sound."
        case .whisper: "Hourly, easing off to daily."
        case .balanced: "10 AM daily, then twice a day, then three times."
        case .easing: "Every 30 min, getting gentler every 12 hours, down to daily."
        case .steady: "After 15 min, then every 2.5 hours."
        case .building: "Starts gentle, getting firmer every 12 hours, up to every 30 min."
        case .nagging: "Every 30 min. After 3 hours, every 15."
        case .unhinged: "Every 8 min. Rings as an alarm after 3 ignored."
        }
    }

    var systemImage: String {
        switch self {
        case .hush: "speaker.slash.fill"
        case .whisper: "wind"
        case .balanced: "sunrise.fill"
        case .easing: "chart.line.downtrend.xyaxis"
        case .steady: "metronome"
        case .building: "chart.line.uptrend.xyaxis"
        case .nagging: "bell.badge.fill"
        case .unhinged: "bolt.fill"
        }
    }

    /// Minutes after capture before the first nog (Balanced goes by its time of day instead).
    var firstDelayMinutes: Int {
        switch self {
        case .hush: 15
        case .whisper: 60
        case .balanced: 1440
        case .easing: 30
        case .steady: 15
        case .building: 60
        case .nagging: 30
        case .unhinged: 2
        }
    }

    /// The (first) gap. Balanced, Easing, Building and Nagging follow their own pattern
    /// (`RepeatCurve`), so for them this is just where it begins.
    var repeatMinutes: Int {
        switch self {
        case .hush: 15
        case .whisper: 60
        case .balanced: 1440
        case .easing: RepeatCurve.Pace.nagging
        case .steady: RepeatCurve.Pace.steady
        case .building: RepeatCurve.Pace.whisper
        case .nagging: RepeatCurve.Pace.nagging
        case .unhinged: 8
        }
    }

    var curve: RepeatCurve {
        switch self {
        case .whisper: .logarithmic
        case .easing: .easingSteps
        case .building: .buildingSteps
        case .nagging: .nagging
        case .balanced: .balanced
        case .hush, .steady, .unhinged: .steady
        }
    }

    /// nil = follow the global "ring as an alarm after" setting; 0 = never.
    /// Easing and Building never ring: an alarm is something you pick (Unhinged, or the
    /// global setting on Steady and Nagging), never something a nog drifts into overnight.
    var escalateAfter: Int? {
        switch self {
        case .hush, .whisper, .balanced, .easing, .building: 0
        case .steady, .nagging: nil
        case .unhinged: 3
        }
    }

    /// The line under the title on this profile's notifications.
    var bannerLine: String {
        switch self {
        case .hush: "Quiet nog."
        case .whisper: "When you're ready."
        case .balanced: "Today's nog."
        case .easing: "Easing off."
        case .steady: "Still here."
        case .building: "Getting firmer."
        case .nagging: "Back again."
        case .unhinged: "Not letting this go."
        }
    }

    /// One step quieter, for a notification's "Gentler" button. nil on profiles that are already quiet.
    var gentler: NogProfile? {
        switch self {
        case .unhinged: .nagging
        case .nagging, .building: .steady
        case .steady, .easing: .whisper
        case .hush, .whisper, .balanced: nil
        }
    }

    /// Nogs once a day or so: their notifications offer "Skip today" instead of "Snooze till 9 AM".
    var skipsDays: Bool { self == .balanced }

    /// No sound and no Time Sensitive break-through, whatever the global settings say.
    var silent: Bool { self == .hush }

    /// Can ring as a real alarm (AlarmKit), which gets through Silent mode and Focus.
    /// Unhinged always can; Steady and Nagging can when Settings › "Ring as an
    /// alarm after" is on (`globalEscalateAfter` > 0). The rest never ring.
    func breaksSilent(globalEscalateAfter: Int) -> Bool {
        !silent && (escalateAfter ?? globalEscalateAfter) > 0
    }

    /// What VoiceOver adds after the name of a profile that `breaksSilent`.
    static let breaksSilentSpoken = "Rings through Silent"

    /// The name VoiceOver reads: "Unhinged, Rings through Silent" when it can.
    func spokenLabel(globalEscalateAfter: Int) -> String {
        breaksSilent(globalEscalateAfter: globalEscalateAfter) ? "\(label), \(Self.breaksSilentSpoken)" : label
    }

    /// Starts at this time of day (minutes after midnight) instead of after a delay.
    /// Balanced lands at 10 AM, so its twice and three-times-a-day nogs fall at 4 PM and 1 PM.
    var timeOfDay: Int? { self == .balanced ? 10 * 60 : nil }

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

    /// Applies this profile's rhythm to a reminder, keeping its start time. Nagging, Easing
    /// and Building go by time since they began, so on a reminder that's already nogging they
    /// begin `now`: picking Building for an old nog starts it gentle, not at full nag.
    func apply(to reminder: Reminder, now: Date = .now) -> Reminder {
        var r = reminder
        r.repeatMinutes = repeatMinutes
        r.curve = curve
        r.escalateAfter = escalateAfter
        r.silent = silent
        r.rampSince = nil // a newly chosen rhythm starts from its beginning
        if curve.timedPhases != nil, r.start < now { r.start = now }
        // "Ring like an alarm" is its own switch: a profile keeps whatever it was.
        return r
    }

    /// A fresh reminder in this profile, starting `firstDelayMinutes` from `now`.
    func reminder(from now: Date = .now) -> Reminder {
        apply(to: Reminder(start: firstStart(from: now)), now: now)
    }

    // MARK: Earlier profiles

    /// Saved with each reminder (`rhythm: 2`), so files from before the November 2026 rework,
    /// which have no such line, are moved onto today's profiles once, as they load.
    static let rhythmVersion = 2

    /// A reminder saved under the old profiles, on today's: old Steady (every 8 min), Easing
    /// (8, 16, 32…), Building (30, 15, 8, 4) and Unhinged (every 7) take the new rhythms, and
    /// Teatime (4 PM every other day) becomes Balanced at 10 AM that day. Its start, alarm switch
    /// and snooze settings stay; anything that matched no old profile is left exactly as it was.
    static func migrateLegacy(_ reminder: Reminder, calendar: Calendar = .current) -> Reminder {
        guard let old = LegacyProfile.matching(reminder) else { return reminder }
        // `now: .distantPast` keeps the start: the ramp counts from when it began.
        var r = old.profile.apply(to: reminder, now: .distantPast)
        if old == .teatime, let ten = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: reminder.start) {
            r.start = ten
        }
        return r
    }

    /// The profiles as they were before the rework, by their saved rhythm.
    enum LegacyProfile: CaseIterable {
        case steady, easing, building, unhinged, teatime

        /// (first delay, repeat, curve, escalate after, time of day) as they were.
        var defaults: (firstDelay: Int, repeatMinutes: Int, curve: RepeatCurve, escalate: Int?, timeOfDay: Int?) {
            switch self {
            case .steady: (15, 8, .steady, nil, nil)
            case .easing: (8, 8, .logarithmic, nil, nil)
            case .building: (30, 30, .building, nil, nil)
            case .unhinged: (2, 7, .steady, 3, nil)
            case .teatime: (0, 2880, .steady, 0, 16 * 60)
            }
        }

        var profile: NogProfile {
            switch self {
            case .steady: .steady
            case .easing: .easing
            case .building: .building
            case .unhinged: .unhinged
            case .teatime: .balanced
            }
        }

        static func matching(_ r: Reminder) -> LegacyProfile? {
            guard !r.silent else { return nil }
            return allCases.first {
                $0.defaults.repeatMinutes == r.repeatMinutes && $0.defaults.curve == r.curve
                    && $0.defaults.escalate == r.escalateAfter
            }
        }
    }

    /// The profile a reminder follows, if it matches one exactly (otherwise it's "Custom").
    static func matching(_ reminder: Reminder) -> NogProfile? {
        allCases.first {
            $0.repeatMinutes == reminder.repeatMinutes && $0.curve == reminder.curve
                && $0.escalateAfter == reminder.escalateAfter && $0.silent == reminder.silent
        }
    }

    /// Capture tokens: `!hush`, `!whisper`, `!balanced` (or `!daily`, `!tea`), `!easing`, `!steady`,
    /// `!building`, `!nagging`, `!unhinged`, or the first few letters of one (`!unh`, `!nag`, `!bui`).
    /// `!gentle` still means Whisper; `!tea` and `!teatime` mean Balanced, which Teatime joined.
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
    /// `!daily` picks Balanced, which replaced Daily (Daily nogs already saved stay as they were).
    /// Teatime was folded into Balanced, so its words pick Balanced too.
    static let aliases: [String: NogProfile] = ["gentle": .whisper, "tea": .balanced, "teatime": .balanced,
                                                "daily": .balanced]

    /// Profiles you can type in a capture: all of them.
    static let tokenProfiles: [NogProfile] = allCases

    /// Shortest abbreviation `token` accepts, so `!u` or `!e` don't switch profile by accident.
    static let minimumPrefix = 3
}
