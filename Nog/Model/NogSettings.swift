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

    static var captureDefaults: CaptureDefaults {
        CaptureDefaults(firstDelayMinutes: firstDelayMinutes, repeatMinutes: repeatMinutes, curve: curve)
    }

    static var defaultReminderFromNow: Reminder {
        Reminder(start: .now.addingTimeInterval(TimeInterval(firstDelayMinutes * 60)),
                 repeatMinutes: repeatMinutes, curve: curve)
    }

    /// Choices offered in pickers (0 = once).
    static let repeatChoices = [0, 1, 2, 5, 8, 10, 15, 20, 30, 45, 60, 120, 240, 480, 1440]

    static func repeatLabel(_ minutes: Int) -> String {
        minutes == 0 ? "Once" : "Every \(IntervalFormat.short(minutes))"
    }

    /// The next "morning" (9 AM unless changed in Nogs & alerts).
    static func nextMorning(after now: Date = .now) -> Date {
        let m = morningMinutes
        return Calendar.current.nextDate(after: now, matching: DateComponents(hour: m / 60, minute: m % 60),
                                         matchingPolicy: .nextTime) ?? now.addingTimeInterval(12 * 3600)
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

enum AppIconChoice: String, CaseIterable, Identifiable {
    case synthwave, spectrum
    var id: String { rawValue }

    var label: String {
        switch self {
        case .synthwave: "Synthwave"
        case .spectrum: "Spectrum"
        }
    }

    /// nil = the primary icon.
    var alternateIconName: String? {
        switch self {
        case .synthwave: nil
        case .spectrum: "AppIcon-Spectrum"
        }
    }

    /// Preview image in the asset catalog.
    var previewImage: String {
        switch self {
        case .synthwave: "IconPreviewSynthwave"
        case .spectrum: "IconPreviewSpectrum"
        }
    }

    static func current(alternateIconName: String?) -> AppIconChoice {
        allCases.first { $0.alternateIconName == alternateIconName } ?? .synthwave
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
            checkInEvery: { let v = int(Key.checkInEvery, 60); return v > 0 ? v : nil }())
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
    static let snoozeChoices = [5, 10, 15, 30, 60, 120]
    static let timesUpChoices = [1, 2, 5, 10, 15]
    static let checkInChoices = [0, 30, 60, 120]
}
