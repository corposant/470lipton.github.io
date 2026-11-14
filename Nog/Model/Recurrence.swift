import Foundation

/// A to-do that comes back: meds every morning, bins every Tuesday, rent on the 1st.
///
/// This is different from a reminder's repeat, which is how often Nog nogs you *until*
/// it's done. A recurring item, marked done, isn't finished: it moves on to its next time
/// and nogs you again then.
struct Recurrence: Hashable {
    enum Rule: Hashable {
        /// Every N days.
        case days(Int)
        /// On these weekdays (Calendar numbering: 1 = Sunday … 7 = Saturday).
        case weekdays(Set<Int>)
        /// Every N weeks, on the start's weekday.
        case weeks(Int)
        /// On this day of each month (31 means the last day in shorter months).
        case monthly(day: Int)
        /// Once a year on this date.
        case yearly(month: Int, day: Int)
    }

    var rule: Rule

    init(_ rule: Rule) { self.rule = rule }

    static let weekdaysOnly: Set<Int> = [2, 3, 4, 5, 6]
    static let weekendOnly: Set<Int> = [1, 7]

    // MARK: - Dates

    /// The first occurrence at or after `candidate`, keeping its time of day.
    /// "every Tuesday" captured on a Sunday starts on Tuesday, "rent on the 1st" on the next 1st.
    func aligned(_ candidate: Date, calendar: Calendar = .current) -> Date {
        let t = calendar.dateComponents([.hour, .minute], from: candidate)
        let dayStart = calendar.startOfDay(for: candidate)
        func at(_ day: Date) -> Date {
            calendar.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: day) ?? day
        }
        switch rule {
        case .days, .weeks:
            return candidate
        case .weekdays(let set):
            guard !set.isEmpty else { return candidate }
            for offset in 0..<8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: dayStart) else { break }
                if set.contains(calendar.component(.weekday, from: day)) { return at(day) }
            }
            return candidate
        case .monthly(let d):
            var month = calendar.dateComponents([.year, .month], from: candidate)
            for _ in 0..<13 {
                if let day = Self.day(d, inYear: month.year, month: month.month, calendar: calendar) {
                    let date = at(day)
                    if date >= candidate || calendar.isDate(day, inSameDayAs: candidate) {
                        return max(date, candidate)
                    }
                }
                month = Self.nextMonth(month, calendar: calendar)
            }
            return candidate
        case .yearly(let m, let d):
            let year = calendar.component(.year, from: candidate)
            for y in year...(year + 4) {
                if let day = Self.day(d, inYear: y, month: m, calendar: calendar) {
                    let date = at(day)
                    if date >= candidate || calendar.isDate(day, inSameDayAs: candidate) {
                        return max(date, candidate)
                    }
                }
            }
            return candidate
        }
    }

    /// The next occurrence after both `date` and the current occurrence `current`,
    /// at `current`'s time of day. Done at 8:05 on the meds that were due at 8:00
    /// → tomorrow 8:00. Done three days late → the next one still ahead.
    func next(after date: Date, from current: Date, calendar: Calendar = .current) -> Date {
        let floor = max(date, current)
        let t = calendar.dateComponents([.hour, .minute], from: current)
        func at(_ day: Date) -> Date {
            calendar.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: day) ?? day
        }
        switch rule {
        case .days(let n), .weeks(let n):
            let stepDays = max(1, n) * (isWeeks ? 7 : 1)
            // Jump most of the way when it's long overdue, then step.
            let behind = floor.timeIntervalSince(current) / 86_400
            var k = max(1, Int(behind) / stepDays)
            for _ in 0..<1000 {
                if let day = calendar.date(byAdding: .day, value: k * stepDays, to: calendar.startOfDay(for: current)) {
                    let candidate = at(day)
                    if candidate > floor { return candidate }
                }
                k += 1
            }
            return floor.addingTimeInterval(TimeInterval(stepDays) * 86_400)
        case .weekdays(let set):
            let days = set.isEmpty ? Set(1...7) : set
            let start = calendar.startOfDay(for: floor)
            for offset in 0..<15 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { break }
                let candidate = at(day)
                if candidate > floor, days.contains(calendar.component(.weekday, from: day)) { return candidate }
            }
            return floor.addingTimeInterval(86_400)
        case .monthly(let d):
            var month = calendar.dateComponents([.year, .month], from: floor)
            for _ in 0..<14 {
                if let day = Self.day(d, inYear: month.year, month: month.month, calendar: calendar) {
                    let candidate = at(day)
                    if candidate > floor { return candidate }
                }
                month = Self.nextMonth(month, calendar: calendar)
            }
            return floor.addingTimeInterval(30 * 86_400)
        case .yearly(let m, let d):
            let year = calendar.component(.year, from: floor)
            for y in year...(year + 8) {
                if let day = Self.day(d, inYear: y, month: m, calendar: calendar) {
                    let candidate = at(day)
                    if candidate > floor { return candidate }
                }
            }
            return floor.addingTimeInterval(365 * 86_400)
        }
    }

    private var isWeeks: Bool {
        if case .weeks = rule { return true }
        return false
    }

    /// Day `d` of a month, clamped to the month's last day (the 31st in April is the 30th).
    private static func day(_ d: Int, inYear year: Int?, month: Int?, calendar: Calendar) -> Date? {
        guard let year, let month,
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: min(max(1, d), range.count)))
    }

    private static func nextMonth(_ c: DateComponents, calendar: Calendar) -> DateComponents {
        var month = (c.month ?? 1) + 1
        var year = c.year ?? 2026
        if month > 12 { month = 1; year += 1 }
        return DateComponents(year: year, month: month)
    }

    // MARK: - Words

    /// "every day", "every Tue and Thu", "weekdays", "every 2 weeks", "monthly on the 1st".
    var summary: String {
        switch rule {
        case .days(1): return "every day"
        case .days(2): return "every other day"
        case .days(let n): return "every \(n) days"
        case .weeks(1): return "every week"
        case .weeks(2): return "every other week"
        case .weeks(let n): return "every \(n) weeks"
        case .weekdays(let set):
            if set == Self.weekdaysOnly { return "every weekday" }
            if set == Self.weekendOnly { return "every weekend day" }
            if set.count == 7 { return "every day" }
            let names = Calendar.current.shortWeekdaySymbols
            // Monday first, Sunday last.
            let ordered = set.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[($0 - 1) % 7] }
            return "every " + ListFormatter.localizedString(byJoining: ordered)
        case .monthly(let d): return "monthly on the \(Self.ordinal(d))"
        case .yearly(let m, let d):
            let month = Calendar.current.monthSymbols[max(0, min(11, m - 1))]
            return "every year on \(month) \(d)"
        }
    }

    /// "every day at 8:00 AM"
    func summary(at time: Date) -> String {
        "\(summary) at \(time.formatted(date: .omitted, time: .shortened))"
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    // MARK: - File format

    /// "days:1", "weekdays:2,4", "weeks:2", "monthly:15", "yearly:11-12"
    var encoded: String {
        switch rule {
        case .days(let n): "days:\(n)"
        case .weekdays(let set): "weekdays:" + set.sorted().map(String.init).joined(separator: ",")
        case .weeks(let n): "weeks:\(n)"
        case .monthly(let d): "monthly:\(d)"
        case .yearly(let m, let d): "yearly:\(m)-\(d)"
        }
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let value = parts[1]
        switch parts[0].lowercased() {
        case "days":
            guard let n = Int(value), (1...ItemValidation.maxRecurrenceInterval).contains(n) else { return nil }
            rule = .days(n)
        case "weeks":
            guard let n = Int(value), (1...ItemValidation.maxRecurrenceInterval).contains(n) else { return nil }
            rule = .weeks(n)
        case "weekdays":
            let set = Set(value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { (1...7).contains($0) })
            guard !set.isEmpty else { return nil }
            rule = .weekdays(set)
        case "monthly":
            guard let d = Int(value), (1...31).contains(d) else { return nil }
            rule = .monthly(day: d)
        case "yearly":
            let md = value.split(separator: "-").compactMap { Int($0) }
            guard md.count == 2, (1...12).contains(md[0]), (1...31).contains(md[1]) else { return nil }
            rule = .yearly(month: md[0], day: md[1])
        default:
            return nil
        }
    }

    // MARK: - Choices for the item page

    /// The simple choices offered on an item's page, from its current time.
    static func choices(for start: Date, calendar: Calendar = .current) -> [Recurrence] {
        let weekday = calendar.component(.weekday, from: start)
        let c = calendar.dateComponents([.month, .day], from: start)
        return [
            Recurrence(.days(1)),
            Recurrence(.weekdays(weekdaysOnly)),
            Recurrence(.weekdays([weekday])),
            Recurrence(.weeks(2)),
            Recurrence(.monthly(day: c.day ?? 1)),
            Recurrence(.yearly(month: c.month ?? 1, day: c.day ?? 1)),
        ]
    }
}
