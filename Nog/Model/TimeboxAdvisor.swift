import Foundation

struct TimeboxSuggestion: Equatable {
    /// nil = open-ended (count up)
    var minutes: Int?
    /// Why, in a few words, e.g. "two-minute start"
    var reason: String

    var label: String {
        guard let minutes else { return "Open-ended" }
        return "\(IntervalFormat.amount(minutes)) · \(reason)"
    }
}

/// The two-minute start: ▶︎ always begins with a short starter timer (Settings › Doing › Starter,
/// 2 min unless changed), whatever the nog. Just the smallest step, with full permission to stop
/// when it ends; past that it counts up and logs the time.
enum TimeboxAdvisor {
    static func suggest(defaultMinutes: Int) -> TimeboxSuggestion {
        let minutes = defaultMinutes > 0 ? defaultMinutes : NogSettings.defaultTimebox
        return TimeboxSuggestion(minutes: minutes,
                                 reason: minutes == 2 ? "two-minute start" : "your starter")
    }
}
