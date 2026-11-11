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
    /// Silence (from the app icon or Settings): nothing nogs or rings before this.
    /// `Date.distantFuture` = until turned back on. Nogs due meanwhile come once it ends.
    var silencedUntil: Date? = nil

    func isSilenced(at date: Date) -> Bool { silencedUntil.map { date < $0 } ?? false }

    /// Silenced with no end (until turned back on), as of `now`.
    func isSilencedIndefinitely(at now: Date) -> Bool {
        silencedUntil.map { $0 == .distantFuture && now < $0 } ?? false
    }

    /// The first moment at or after `date` a nog may go out: after any silence, outside
    /// quiet hours. nil while silenced with no end.
    func nextAllowed(after date: Date, calendar: Calendar = .current) -> Date? {
        var d = date
        if let until = silencedUntil, d < until {
            guard until != .distantFuture else { return nil }
            d = until
        }
        return quiet.nextOpening(after: d, calendar: calendar)
    }

    static let standard = NogPolicy()
}

extension NogPolicy {
    /// When this reminder's next nogs will actually arrive: like the planner, a nog that
    /// falls in quiet hours moves to when they end (and several can land together).
    func deliveryDates(for reminder: Reminder, after date: Date, limit: Int,
                       calendar: Calendar = .current) -> [Date] {
        guard limit > 0 else { return [] }
        // Nothing quiet or silenced ahead: the fire times are the delivery times. (The common
        // case, and called for every row and widget entry, so skip the look-ahead below.)
        if !quiet.enabled && !isSilenced(at: date) {
            return reminder.fireDates(after: date, limit: limit)
        }
        var result: [Date] = []
        var seen = Set<Date>()
        // A long quiet stretch folds many fire times into one, so look further ahead.
        for fire in reminder.fireDates(after: date, limit: limit + 400) {
            guard let when = nextAllowed(after: fire, calendar: calendar) else { return [] }
            if seen.insert(when).inserted { result.append(when) }
            if result.count == limit { break }
        }
        return result
    }
}

extension Reminder {
    /// When the nog after `count` ignored ones fires (escalation point). Nil if it never repeats.
    func escalationDate(afterIgnored count: Int) -> Date? {
        guard count > 0, repeatMinutes != nil else { return nil }
        return fireDates(after: start.addingTimeInterval(-1), limit: count + 1).last
    }
}
