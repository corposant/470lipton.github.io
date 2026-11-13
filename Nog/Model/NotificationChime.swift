import Foundation

/// Settings › Timing & alerts › Chime: the sound a nog plays.
/// The chimes are about a second long, soft and never harsh, and come from the same
/// celesta-like family as the two-minute starter chime (design/sounds/make_notification_chimes.py).
enum NotificationChime: String, CaseIterable, Identifiable {
    /// Gentle profiles nudge, loud ones insist, and heads-ups ripple.
    case matchProfile = "match"
    case nudge, ripple, insist
    /// The iPhone's own notification sound.
    case system

    static let key = "notificationChime"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .matchProfile: "Match profile"
        case .nudge: "Nudge"
        case .ripple: "Ripple"
        case .insist: "Insist"
        case .system: "iPhone default"
        }
    }

    /// A short description for the picker and VoiceOver.
    var detail: String {
        switch self {
        case .matchProfile: "Gentle nogs nudge, Building and Unhinged insist, heads-ups ripple."
        case .nudge: "Two soft notes going up."
        case .ripple: "Four soft notes falling."
        case .insist: "Brighter notes, played twice."
        case .system: "The usual iPhone sound."
        }
    }

    /// The bundled sound file (Nog/Resources), or nil for the system sound.
    var fileName: String? {
        switch self {
        case .nudge: "NudgeChime.caf"
        case .ripple: "RippleChime.caf"
        case .insist: "InsistChime.caf"
        case .matchProfile, .system: nil
        }
    }

    /// The chime to play for one notification. `firm` is a nog that builds or can ring as an alarm.
    func resolved(isHeadsUp: Bool, firm: Bool) -> NotificationChime {
        guard self == .matchProfile else { return self }
        if isHeadsUp { return .ripple }
        return firm ? .insist : .nudge
    }

    /// Building and Unhinged (or a custom rhythm that builds or rings as an alarm) insist.
    static func isFirm(_ reminder: Reminder) -> Bool {
        reminder.curve == .building || (reminder.escalateAfter ?? 0) > 0
    }

    static var current: NotificationChime {
        NotificationChime(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .matchProfile
    }
}
