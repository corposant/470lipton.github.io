import Foundation

/// Nog's own sounds, from the same soft, celesta-like family as the two-minute starter chime
/// (design/sounds/make_notification_chimes.py). Settings › Timing & alerts picks one for
/// reminders (Nodge by default) and one for alarms (Heyhey by default).
enum NotificationChime: String, CaseIterable, Identifiable {
    case nodge, bipple, heyhey
    /// The iPhone's own sound.
    case system

    static let reminderKey = "reminderChime"
    static let alarmKey = "alarmChime"
    static let reminderDefault = NotificationChime.nodge
    static let alarmDefault = NotificationChime.heyhey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nodge: "Nodge"
        case .bipple: "Bipple"
        case .heyhey: "Heyhey"
        case .system: "iPhone default"
        }
    }

    /// A short description for the picker and VoiceOver.
    var detail: String {
        switch self {
        case .nodge: "Two soft notes going up."
        case .bipple: "Four soft notes falling."
        case .heyhey: "Brighter notes, played twice."
        case .system: "The usual iPhone sound."
        }
    }

    /// The bundled sound file (Nog/Resources), or nil for the iPhone's own sound.
    var fileName: String? {
        switch self {
        case .nodge: "NodgeChime.caf"
        case .bipple: "BippleChime.caf"
        case .heyhey: "HeyheyChime.caf"
        case .system: nil
        }
    }

    /// The chime for nog notifications (and heads-ups).
    static var reminder: NotificationChime { stored(reminderKey) ?? reminderDefault }
    /// The sound AlarmKit alarms ring with.
    static var alarm: NotificationChime { stored(alarmKey) ?? alarmDefault }

    private static func stored(_ key: String) -> NotificationChime? {
        NotificationChime(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
    }
}
