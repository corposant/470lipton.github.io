import Foundation

/// User-adjustable defaults (edited in SettingsView via @AppStorage with the same keys).
enum NogSettings {
    static let firstDelayKey = "firstDelayMinutes"
    static let repeatKey = "repeatMinutes"
    static let curveKey = "repeatCurve"
    static let timeboxKey = "defaultTimeboxMinutes"
    static let defaultTimebox = 25

    /// Default ▶︎ timebox in minutes; 0 = open-ended.
    static var timeboxMinutes: Int {
        UserDefaults.standard.object(forKey: timeboxKey) as? Int ?? defaultTimebox
    }

    static let timeboxChoices = [5, 10, 15, 25, 30, 45, 60, 90, 120]

    static let defaultFirstDelay = 15
    static let defaultRepeat = 8

    /// Minutes after capture before the first nog.
    static var firstDelayMinutes: Int {
        UserDefaults.standard.object(forKey: firstDelayKey) as? Int ?? defaultFirstDelay
    }

    /// Minutes between nogs; nil = remind once.
    static var repeatMinutes: Int? {
        let value = UserDefaults.standard.object(forKey: repeatKey) as? Int ?? defaultRepeat
        return value > 0 ? value : nil
    }

    /// Steady or logarithmic, for new captures.
    static var curve: RepeatCurve {
        UserDefaults.standard.string(forKey: curveKey).flatMap(RepeatCurve.init(rawValue:)) ?? .steady
    }

    static let escalateKey = "defaultEscalateAfter" // -1 = follow the global setting

    /// Per-capture escalation from the default profile (nil = global "ring as an alarm after").
    static var defaultEscalateAfter: Int? {
        let v = UserDefaults.standard.object(forKey: escalateKey) as? Int ?? -1
        return v >= 0 ? v : nil
    }

    static var captureDefaults: CaptureDefaults {
        CaptureDefaults(firstDelayMinutes: firstDelayMinutes, repeatMinutes: repeatMinutes, curve: curve,
                        escalateAfter: defaultEscalateAfter)
    }

    static var defaultReminderFromNow: Reminder {
        Reminder(start: .now.addingTimeInterval(TimeInterval(firstDelayMinutes * 60)),
                 repeatMinutes: repeatMinutes, curve: curve, escalateAfter: defaultEscalateAfter)
    }

    /// The profile new captures use, if the defaults match one exactly.
    static var defaultProfile: NogProfile? {
        NogProfile.allCases.first {
            $0.firstDelayMinutes == firstDelayMinutes && $0.repeatMinutes == repeatMinutes
                && $0.curve == curve && $0.escalateAfter == defaultEscalateAfter
        }
    }

    /// Makes a profile the default for new captures.
    static func setDefaultProfile(_ profile: NogProfile) {
        let d = UserDefaults.standard
        d.set(profile.firstDelayMinutes, forKey: firstDelayKey)
        d.set(profile.repeatMinutes, forKey: repeatKey)
        d.set(profile.curve.rawValue, forKey: curveKey)
        d.set(profile.escalateAfter ?? -1, forKey: escalateKey)
    }

    /// Choices offered in pickers (0 = once).
    static let repeatChoices = [0, 1, 2, 5, 8, 10, 15, 20, 30, 45, 60, 120, 240, 480, 1440]

    static func repeatLabel(_ minutes: Int) -> String {
        minutes == 0 ? "No repeat" : "Every \(IntervalFormat.short(minutes))"
    }

    /// "Snooze till 9 AM" (or whatever "morning" is set to).
    static var morningLabel: String { morningSnoozeLabel(minutes: morningMinutes) }

    /// The next "morning" (9 AM unless changed in Nogs & alerts, or for this item).
    static func nextMorning(after now: Date = .now, minutes: Int? = nil) -> Date {
        let m = minutes ?? morningMinutes
        return Calendar.current.nextDate(after: now, matching: DateComponents(hour: m / 60, minute: m % 60),
                                         matchingPolicy: .nextTime) ?? now.addingTimeInterval(12 * 3600)
    }

    // MARK: Per-item snooze

    /// This item's snooze length (its own, or the default).
    static func snoozeLength(for item: Item) -> Int {
        item.reminder?.snoozeMinutes ?? snoozeMinutes
    }

    /// When "Snooze till morning" would move this item to.
    static func nextMorning(for item: Item, after now: Date = .now) -> Date {
        nextMorning(after: now, minutes: item.reminder?.morningMinutes)
    }

    /// "Snooze 1 hour" for this item.
    static func snoozeLabel(minutes: Int) -> String {
        "Snooze \(IntervalFormat.amount(minutes))"
    }

    /// "Snooze till 9 AM" for a morning time (minutes after midnight).
    static func morningSnoozeLabel(minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        return "Snooze till \(date.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Control panel choices

enum ThemeMode: String, CaseIterable, Identifiable {
    case auto, dark, light
    var id: String { rawValue }

    static let key = "themeMode"

    var label: String {
        switch self {
        case .auto: "Auto"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

/// The nog carton: inked comix on cream (primary), or neon-hatched on charcoal.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case comix, neon
    var id: String { rawValue }

    var label: String {
        switch self {
        case .comix: "Comix"
        case .neon: "Neon"
        }
    }

    /// nil = the primary icon.
    var alternateIconName: String? {
        switch self {
        case .comix: nil
        case .neon: "AppIcon-Neon"
        }
    }

    /// Preview image in the asset catalog.
    var previewImage: String {
        switch self {
        case .comix: "IconPreviewComix"
        case .neon: "IconPreviewNeon"
        }
    }

    /// An icon name this version doesn't have (e.g. an old alternate) counts as the primary.
    static func current(alternateIconName: String?) -> AppIconChoice {
        allCases.first { $0.alternateIconName == alternateIconName } ?? .comix
    }
}

enum StorageMode: String, CaseIterable, Identifiable {
    case iCloud = "icloud", local
    var id: String { rawValue }

    static let key = "storageMode"

    static var current: StorageMode {
        UserDefaults.standard.string(forKey: key).flatMap(StorageMode.init(rawValue:)) ?? .iCloud
    }

    var label: String {
        switch self {
        case .iCloud: "iCloud Drive"
        case .local: "On this iPhone"
        }
    }
}

// MARK: - Nogs & alerts (Control Panel)

extension NogSettings {
    enum Key {
        static let quietEnabled = "quietEnabled"
        static let quietStart = "quietStart"          // minutes after midnight
        static let quietEnd = "quietEnd"
        static let quietWeekends = "quietWeekends"
        static let headsUp = "headsUpMinutes"
        static let escalateAfter = "escalateAfter"
        static let snoozeMinutes = "snoozeMinutes"
        static let morningMinutes = "morningMinutes"  // minutes after midnight
        static let timeSensitive = "timeSensitive"
        static let sound = "notificationSound"
        static let showTitles = "showTitlesOnLockScreen"
        static let badge = "appIconBadge"
        static let timesUpEvery = "timesUpEvery"
        static let checkInEvery = "checkInEvery"     // 0 = off
        static let liveActivity = "liveActivityEnabled"
    }

    private static func int(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static var policy: NogPolicy {
        NogPolicy(
            quiet: QuietHours(enabled: bool(Key.quietEnabled, false),
                              start: int(Key.quietStart, 22 * 60),
                              end: int(Key.quietEnd, 7 * 60),
                              weekends: bool(Key.quietWeekends, false)),
            headsUpMinutes: int(Key.headsUp, 0),
            escalateAfter: int(Key.escalateAfter, 0),
            timesUpEvery: int(Key.timesUpEvery, 5),
            checkInEvery: { let v = int(Key.checkInEvery, 60); return v > 0 ? v : nil }(),
            silencedUntil: silencedUntil)
    }

    // MARK: Silence

    static let silencedUntilKey = "silencedUntil"

    /// When silence ends (`.distantFuture` = until turned back on), or nil when not silenced.
    /// Stored on this device only.
    static var silencedUntil: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: silencedUntilKey)
            guard t != 0 else { return nil }
            let date = Date(timeIntervalSinceReferenceDate: t)
            return date > .now ? date : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSinceReferenceDate, forKey: silencedUntilKey)
            } else {
                UserDefaults.standard.removeObject(forKey: silencedUntilKey)
            }
        }
    }

    /// "Silenced until 5:30 PM", "Silenced until tomorrow 9:00 AM", "Silenced until you turn nogs back on".
    static func silenceLabel(_ until: Date, now: Date = .now) -> String {
        if until == .distantFuture { return "Silenced until you turn nogs back on" }
        let time = until.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(until, inSameDayAs: now) { return "Silenced until \(time)" }
        let day = Calendar.current.isDateInTomorrow(until) ? "tomorrow" : until.formatted(.dateTime.weekday(.wide))
        return "Silenced until \(day) \(time)"
    }

    static var snoozeMinutes: Int { int(Key.snoozeMinutes, 60) }
    static var morningMinutes: Int { int(Key.morningMinutes, 9 * 60) }
    static var timeSensitive: Bool { bool(Key.timeSensitive, true) }
    static var playsSound: Bool { bool(Key.sound, true) }
    static var showTitles: Bool { bool(Key.showTitles, true) }
    static var showsBadge: Bool { bool(Key.badge, false) }
    static var liveActivityEnabled: Bool { bool(Key.liveActivity, true) }

    static let headsUpChoices = [0, 5, 10, 15, 30, 60]
    static let escalateChoices = [0, 3, 5, 10, 20]
    /// Snooze lengths, for the Settings default and each item's own.
    static let snoozeChoices = [5, 10, 15, 30, 60, 120, 180, 240, 480]
    static let timesUpChoices = [1, 2, 5, 10, 15]
    static let checkInChoices = [0, 30, 60, 120]
}
