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

    /// The next 9 AM.
    static func nextMorning(after now: Date = .now) -> Date {
        Calendar.current.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0),
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
