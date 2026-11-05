import Foundation

/// Quiet hours: no nogs in this window (they wait until it ends).
struct QuietHours: Equatable {
    var enabled = false
    /// Minutes after midnight.
    var start = 22 * 60
    var end = 7 * 60
    /// Keep all of Saturday and Sunday quiet too.
    var weekends = false

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        if weekends && calendar.isDateInWeekend(date) { return true }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if start == end { return false }
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// The first moment at or after `date` that isn't quiet.
    func nextOpening(after date: Date, calendar: Calendar = .current) -> Date {
        guard contains(date, calendar: calendar) else { return date }
        // Jump straight to today's/tomorrow's end time, then step past weekends if needed.
        let endHour = end / 60, endMinute = end % 60
        var candidate = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: date) ?? date
        if candidate <= date { candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate }
        var guardDays = 0
        while contains(candidate, calendar: calendar) && guardDays < 8 {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            candidate = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: candidate) ?? candidate
            guardDays += 1
        }
        return candidate
    }
}

/// Everything the user can tune about how nogs behave (Control Panel → Nogs & alerts).
struct NogPolicy: Equatable {
    var quiet = QuietHours()
    /// A gentle "coming up" note this many minutes before a dated nog starts (0 = off).
    var headsUpMinutes = 0
    /// After this many ignored nogs, an item starts ringing as an alarm (0 = never).
    var escalateAfter = 0
    /// While doing: how often "time's up" repeats.
    var timesUpEvery = 5
    /// While doing open-ended: an hourly-ish "still on it?" (nil = off).
    var checkInEvery: Int? = 60

    static let standard = NogPolicy()
}

extension Reminder {
    /// When the nog after `count` ignored ones fires (escalation point). Nil if it never repeats.
    func escalationDate(afterIgnored count: Int) -> Date? {
        guard count > 0, repeatMinutes != nil else { return nil }
        return fireDates(after: start.addingTimeInterval(-1), limit: count + 1).last
    }
}
