import Foundation

/// What the natural-language pass found in a capture line.
struct ParsedWhen: Equatable {
    /// When to start nogging, if the text said so.
    var start: Date?
    /// How often to nog until done, from "every 10 min", "every 2 hours", "hourly"…
    var repeatMinutes: Int?
    /// A to-do that comes back after it's done, from "every day", "every Tuesday",
    /// "every weekday", "every 2 weeks", "monthly", "daily"…
    var recurrence: Recurrence? = nil
    /// The text with the date/time words taken out.
    var title: String
}

/// Understands everyday phrases like:
///
///   lunch next Tues · call mom tomorrow at 3 · pay rent friday
///   dentist nov 12 at 2:30pm · stretch in 20 min · report by eod
///   pills every 4 hours · standup tomorrow morning · dinner with Sam on sat
///   meds every morning · bins every tue · rent every month on the 1st · gym every mon and thu
///
/// Meal words (breakfast, lunch, dinner…) stay in the title but set the time
/// when a day is given: "lunch next Tues" → "Lunch", Tuesday 12:00.
enum NaturalDateParser {
    static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> ParsedWhen {
        var p = Parser(text: text, now: now, calendar: calendar)
        return p.run()
    }
}

private struct Parser {
    let raw: [String]
    let words: [String]
    let now: Date
    let calendar: Calendar
    var consumed: [Bool]

    // What we've learned
    var day: Date?                     // start of a specific day
    var explicitTime: (h: Int, m: Int, hasMeridiem: Bool)?
    var partOfDay: (h: Int, m: Int)?   // morning / afternoon / evening / night
    var defaultTime: (h: Int, m: Int)? // tonight, eod, weekend…
    var relative: TimeInterval?
    var repeatMinutes: Int?
    var rule: Recurrence.Rule?
    /// "every month" with no day: the day comes from the start (0 = not set yet).
    var monthlyFromStart = false
    var yearlyFromStart = false
    var pmContext = false

    init(text: String, now: Date, calendar: Calendar) {
        raw = text.split(whereSeparator: \.isWhitespace).map(String.init)
        words = raw.map { Parser.normalize($0) }
        self.now = now
        self.calendar = calendar
        consumed = Array(repeating: false, count: raw.count)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;!?()\"'"))
    }

    // MARK: - Run

    mutating func run() -> ParsedWhen {
        var i = 0
        while i < words.count {
            if !consumed[i], let length = match(at: i) {
                for k in i..<min(i + length, words.count) { consumed[k] = true }
                i += length
            } else {
                i += 1
            }
        }
        absorbPartsOfDay()
        absorbDanglingConnectors()

        let meal = mealTime()
        if let meal, meal.h >= 17 { pmContext = true }

        var start: Date?
        if let relative {
            start = now.addingTimeInterval(relative)
        } else if day != nil || explicitTime != nil || partOfDay != nil || defaultTime != nil {
            var h = 9, m = 0
            if let t = explicitTime {
                h = t.h; m = t.m
                if !t.hasMeridiem && h < 12 && (h < 7 || pmContext) { h += 12 }
            } else if let t = partOfDay {
                h = t.h; m = t.m
            } else if let t = meal {
                h = t.h; m = t.m
            } else if let t = defaultTime {
                h = t.h; m = t.m
            }
            let base = day ?? calendar.startOfDay(for: now)
            var date = calendar.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
            if day == nil && date <= now {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            start = date
        }

        // A recurring item starts on its first matching day, at the time given (9 AM by default).
        var recurrence: Recurrence?
        if var rule {
            var first = start ?? {
                let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
                return nine > now ? nine : calendar.date(byAdding: .day, value: 1, to: nine) ?? nine
            }()
            if monthlyFromStart { rule = .monthly(day: calendar.component(.day, from: first)) }
            if yearlyFromStart {
                let c = calendar.dateComponents([.month, .day], from: first)
                rule = .yearly(month: c.month ?? 1, day: c.day ?? 1)
            }
            let r = Recurrence(rule)
            first = r.aligned(first, calendar: calendar)
            if first <= now { first = r.next(after: now, from: first, calendar: calendar) }
            start = first
            recurrence = r
        }

        let titleWords = raw.indices.filter { !consumed[$0] }.map { raw[$0] }
        var title = titleWords.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;-–—"))
        if let first = title.first, first.isLowercase {
            title = first.uppercased() + title.dropFirst()
        }
        return ParsedWhen(start: start, repeatMinutes: repeatMinutes, recurrence: recurrence, title: title)
    }

    // MARK: - Matching

    func word(_ i: Int) -> String? { i < words.count && i >= 0 && !consumed[i] ? words[i] : nil }

    mutating func match(at i: Int) -> Int? {
        let w = words[i]

        // Repeats
        if w == "every" || w == "each" { return matchEvery(at: i) }
        if w == "hourly" { repeatMinutes = 60; return 1 }
        switch w {
        case "daily", "everyday", "nightly": rule = .days(1); if w == "nightly" { partOfDay = (20, 0); pmContext = true }; return 1
        case "weekly": rule = .weeks(1); return 1
        case "fortnightly", "biweekly": rule = .weeks(2); return 1
        case "monthly": rule = .monthly(day: 0); monthlyFromStart = true; return 1 + monthDay(at: i + 1)
        case "yearly", "annually": rule = .yearly(month: 0, day: 0); yearlyFromStart = true; return 1
        default: break
        }

        // Relative: in 20 min, in an hour, in half an hour, in 2h, in the morning
        if w == "in" { return matchIn(at: i) }

        // Single-word days
        switch w {
        case "today": day = startOfToday; return 1
        case "tonight": day = startOfToday; defaultTime = (20, 0); pmContext = true; return 1
        case "tomorrow", "tmrw", "tmr", "tomorow", "tommorow", "tommorrow":
            day = addDays(1); return 1
        case "overmorrow": day = addDays(2); return 1
        case "eod": day = startOfToday; defaultTime = (17, 0); return 1
        case "weekend": day = nextWeekday(7, allowToday: true); defaultTime = (10, 0); return 1
        case "noon", "midday": explicitTime = (12, 0, true); return 1
        case "midnight": explicitTime = (23, 59, true); return 1
        default: break
        }
        if w == "day", word(i + 1) == "after", word(i + 2).map(Parser.isTomorrow) == true {
            day = addDays(2); return 3
        }
        if w == "end", word(i + 1) == "of", word(i + 2) == "day" {
            day = startOfToday; defaultTime = (17, 0); return 3
        }

        // Connector words that introduce a date or time: next, this, on, at, by…
        if ["next", "this", "coming", "on", "by", "at", "due", "before", "until", "til", "till"].contains(w),
           let length = matchAfterConnector(w, at: i) {
            return length
        }

        // Bare weekday (ambiguous ones like "sat", "sun", "wed" need a connector)
        if let wd = Parser.weekday(w), !Parser.ambiguousWeekdays.contains(w) {
            day = nextWeekday(wd, allowToday: false); return 1
        }

        // Month dates: nov 12, november 12th, 12 nov, 12th of november
        if let length = matchMonthDate(at: i) { return length }

        // Times: 3pm, 3:30pm, 15:00, 3 pm
        if case let (t, length)? = matchTime(at: i, allowBareNumber: false) { explicitTime = t; return length }

        return nil
    }

    mutating func matchEvery(at i: Int) -> Int? {
        guard let next = word(i + 1) else { return nil }
        // Things that come back: every morning, every weekday, every tue and thu, every month…
        if let pod = Parser.partOfDay(next) {
            rule = .days(1); partOfDay = pod; if pod.h >= 12 { pmContext = true }; return 2
        }
        switch next {
        case "weekday", "weekdays": rule = .weekdays(Recurrence.weekdaysOnly); return 2
        case "weekend", "weekends": rule = .weekdays(Recurrence.weekendOnly); defaultTime = (10, 0); return 2
        case "month": rule = .monthly(day: 0); monthlyFromStart = true; return 2 + monthDay(at: i + 2)
        case "year": rule = .yearly(month: 0, day: 0); yearlyFromStart = true; return 2
        default: break
        }
        if Parser.weekday(next) != nil {
            // "every mon", "every tue and thu", "every mon, wed, fri"
            var days = Set<Int>()
            var k = i + 1
            var length = 1
            while let w = word(k) {
                if let wd = Parser.weekday(w) {
                    days.insert(wd); k += 1; length = k - i
                } else if w == "and" || w == "&" || w.isEmpty, word(k + 1).flatMap(Parser.weekday) != nil {
                    k += 1
                } else {
                    break
                }
            }
            rule = .weekdays(days); return length
        }
        if next == "other", let unit = word(i + 2).flatMap(Parser.unitMinutes) {
            setEvery(minutes: unit * 2); return 3
        }
        if next == "half", word(i + 2) == "hour" || word(i + 2) == "an" && word(i + 3) == "hour" {
            repeatMinutes = 30; return word(i + 2) == "an" ? 4 : 3
        }
        if let compact = Parser.compactDuration(next) { setEvery(minutes: compact); return 2 }
        if let unit = Parser.unitMinutes(next) { setEvery(minutes: unit); return 2 }
        if let n = Parser.number(next), let unit = word(i + 2).flatMap(Parser.unitMinutes) {
            setEvery(minutes: n * unit); return 3
        }
        if let n = Parser.number(next), ["months", "month"].contains(word(i + 2) ?? ""), n == 1 {
            rule = .monthly(day: 0); monthlyFromStart = true; return 3
        }
        return nil
    }

    /// Under a day is how often to nog ("every 4 hours"); whole days or weeks mean
    /// the item comes back ("every 2 days", "every week").
    mutating func setEvery(minutes: Int) {
        if minutes >= 10_080, minutes % 10_080 == 0 {
            rule = .weeks(minutes / 10_080)
        } else if minutes >= 1440, minutes % 1440 == 0 {
            rule = .days(minutes / 1440)
        } else {
            repeatMinutes = minutes
        }
    }

    /// "… on the 1st" / "on the 15th" after "every month": sets the day, returns words used.
    mutating func monthDay(at i: Int) -> Int {
        var k = i
        if word(k) == "on" { k += 1 }
        if word(k) == "the" { k += 1 }
        guard let w = word(k), w.count <= 4,
              w.contains(where: \.isLetter), let d = Parser.dayOfMonth(w) else { return 0 }
        rule = .monthly(day: d); monthlyFromStart = false
        return k - i + 1
    }

    mutating func matchIn(at i: Int) -> Int? {
        guard let next = word(i + 1) else { return nil }
        if let compact = Parser.compactDuration(next) {
            relative = TimeInterval(compact * 60); return 2
        }
        if next == "half", word(i + 2) == "an", word(i + 3) == "hour" {
            relative = 1800; return 4
        }
        if let n = Parser.number(next), let unit = word(i + 2).flatMap(Parser.unitMinutes) {
            relative = TimeInterval(n * unit * 60); return 3
        }
        if next == "the", let pod = word(i + 2).flatMap(Parser.partOfDay) {
            partOfDay = pod; if pod.h >= 12 { pmContext = true }; return 3
        }
        return nil
    }

    mutating func matchAfterConnector(_ connector: String, at i: Int) -> Int? {
        guard let next = word(i + 1) else { return nil }

        if connector == "next" || connector == "this" || connector == "coming" {
            switch next {
            case "week":
                day = connector == "this" ? startOfToday : nextWeekday(2, allowToday: false)
                return 2
            case "month":
                if connector == "this" { day = startOfToday; return 2 }
                let comps = calendar.dateComponents([.year, .month], from: now)
                if let firstOfThis = calendar.date(from: comps) {
                    day = calendar.date(byAdding: .month, value: 1, to: firstOfThis)
                }
                return 2
            case "weekend":
                day = nextWeekday(7, allowToday: true); defaultTime = (10, 0); return 2
            default:
                break
            }
            if connector == "this", let pod = Parser.partOfDay(next) {
                day = startOfToday; partOfDay = pod; if pod.h >= 12 { pmContext = true }; return 2
            }
        }

        if let wd = Parser.weekday(next) {
            day = nextWeekday(wd, allowToday: connector == "this")
            return 2
        }
        if ["today", "tonight", "tomorrow", "tmrw", "tmr", "eod", "noon", "midnight"].contains(next) {
            return nil // let the single-word rule handle it; connector stays in title, then gets absorbed
        }
        if let length = matchMonthDate(at: i + 1) { return length + 1 }
        if case let (t, length)? = matchTime(at: i + 1, allowBareNumber: connector == "at") {
            explicitTime = t; return length + 1
        }
        return nil
    }

    mutating func matchMonthDate(at i: Int) -> Int? {
        guard let w = word(i) else { return nil }
        // nov 12 / november 12th
        if let month = Parser.month(w), let d = word(i + 1).flatMap(Parser.dayOfMonth) {
            day = dateFor(month: month, day: d); return 2
        }
        // 12 nov / 12th nov / 12th of november
        if let d = Parser.dayOfMonth(w) {
            if let month = word(i + 1).flatMap(Parser.month) {
                day = dateFor(month: month, day: d); return 2
            }
            if word(i + 1) == "of", let month = word(i + 2).flatMap(Parser.month) {
                day = dateFor(month: month, day: d); return 3
            }
        }
        return nil
    }

    func matchTime(at i: Int, allowBareNumber: Bool) -> ((h: Int, m: Int, hasMeridiem: Bool), Int)? {
        guard let w = word(i) else { return nil }
        if w == "noon" || w == "midday" { return ((12, 0, true), 1) }
        if w == "midnight" { return ((23, 59, true), 1) }

        let compact = w.replacingOccurrences(of: ".", with: "")
        // 3pm, 3:30pm, 3p
        for (suffix, pm) in [("pm", true), ("am", false), ("p", true), ("a", false)] where compact.hasSuffix(suffix) {
            if case let (h, m)? = Parser.clock(String(compact.dropLast(suffix.count))), (1...12).contains(h) {
                return ((Parser.to24(h, pm: pm), m, true), 1)
            }
        }
        if case let (h, m)? = Parser.clock(compact) {
            // 3 pm (separate token)
            if let next = word(i + 1)?.replacingOccurrences(of: ".", with: ""), next == "pm" || next == "am",
               (1...12).contains(h) {
                return ((Parser.to24(h, pm: next == "pm"), m, true), 2)
            }
            // 15:00 or 3:30
            if compact.contains(":"), (0...23).contains(h) { return ((h, m, h >= 13 || h == 0), 1) }
            // "at 3"
            if allowBareNumber, (0...23).contains(h) { return ((h, m, h >= 13 || h == 0), 1) }
        }
        return nil
    }

    // MARK: - Post passes

    /// "tomorrow morning", "tues evening": a part-of-day word next to a date/time word.
    mutating func absorbPartsOfDay() {
        for i in words.indices where !consumed[i] {
            guard let pod = Parser.partOfDay(words[i]) else { continue }
            let leftConsumed = i > 0 && consumed[i - 1]
            let rightConsumed = i + 1 < words.count && consumed[i + 1]
            if leftConsumed || rightConsumed {
                consumed[i] = true
                partOfDay = pod
                if pod.h >= 12 { pmContext = true }
            }
        }
    }

    /// Drops "on", "at", "by"… left hanging right before a consumed date word.
    mutating func absorbDanglingConnectors() {
        let connectors: Set<String> = ["on", "at", "by", "due", "before", "until", "til", "till", "for", "this", "next"]
        for i in words.indices.reversed() where !consumed[i] && connectors.contains(words[i]) {
            if i + 1 < words.count && consumed[i + 1] { consumed[i] = true }
        }
    }

    func mealTime() -> (h: Int, m: Int)? {
        guard day != nil || defaultTime != nil else { return nil }
        for w in words {
            switch w {
            case "breakfast": return (8, 0)
            case "brunch": return (11, 0)
            case "lunch": return (12, 0)
            case "dinner", "supper": return (18, 30)
            default: continue
            }
        }
        return nil
    }

    // MARK: - Calendar helpers

    var startOfToday: Date { calendar.startOfDay(for: now) }

    func addDays(_ n: Int) -> Date? {
        calendar.date(byAdding: .day, value: n, to: startOfToday)
    }

    /// Next date with this weekday (1 = Sunday … 7 = Saturday).
    func nextWeekday(_ weekday: Int, allowToday: Bool) -> Date? {
        let today = calendar.component(.weekday, from: now)
        var delta = (weekday - today + 7) % 7
        if delta == 0 && !allowToday { delta = 7 }
        return addDays(delta)
    }

    func dateFor(month: Int, day d: Int) -> Date? {
        let year = calendar.component(.year, from: now)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: d)) else { return nil }
        if date < startOfToday {
            return calendar.date(from: DateComponents(year: year + 1, month: month, day: d))
        }
        return date
    }

    static func isTomorrow(_ w: String) -> Bool { ["tomorrow", "tmrw", "tmr"].contains(w) }

    // MARK: - Vocabulary

    static let ambiguousWeekdays: Set<String> = ["sun", "sat", "wed", "mon"]

    static func weekday(_ w: String) -> Int? {
        switch w {
        case "sunday", "sun": 1
        case "monday", "mon": 2
        case "tuesday", "tues", "tue": 3
        case "wednesday", "wed", "weds": 4
        case "thursday", "thurs", "thur", "thu": 5
        case "friday", "fri": 6
        case "saturday", "sat": 7
        default: nil
        }
    }

    static func month(_ w: String) -> Int? {
        switch w {
        case "january", "jan": 1
        case "february", "feb": 2
        case "march", "mar": 3
        case "april", "apr": 4
        case "may": 5
        case "june", "jun": 6
        case "july", "jul": 7
        case "august", "aug": 8
        case "september", "sept", "sep": 9
        case "october", "oct": 10
        case "november", "nov": 11
        case "december", "dec": 12
        default: nil
        }
    }

    static func partOfDay(_ w: String) -> (h: Int, m: Int)? {
        switch w {
        case "morning": (9, 0)
        case "afternoon": (15, 0)
        case "evening": (18, 0)
        case "night": (20, 0)
        default: nil
        }
    }

    static func unitMinutes(_ w: String) -> Int? {
        switch w {
        case "m", "min", "mins", "minute", "minutes": 1
        case "h", "hr", "hrs", "hour", "hours": 60
        case "d", "day", "days": 1440
        case "w", "wk", "wks", "week", "weeks": 10080
        default: nil
        }
    }

    static func number(_ w: String) -> Int? {
        if let n = Int(w), n > 0, n <= 10_000 { return n }
        let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                     "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
                     "fifteen": 15, "twenty": 20, "thirty": 30, "forty-five": 45, "few": 3, "couple": 2]
        return words[w]
    }

    /// "20m", "2h", "90min", "1hr", "2d", "1w"
    static func compactDuration(_ w: String) -> Int? {
        let digits = w.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < w.count, let n = Int(digits), n > 0 else { return nil }
        guard let unit = unitMinutes(String(w.dropFirst(digits.count))) else { return nil }
        return n * unit
    }

    static func dayOfMonth(_ w: String) -> Int? {
        var s = Substring(w)
        for suffix in ["st", "nd", "rd", "th"] where s.hasSuffix(suffix) { s = s.dropLast(2); break }
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let d = Int(s), (1...31).contains(d) else { return nil }
        return d
    }

    /// "3" → (3, 0), "3:30" → (3, 30), "15:00" → (15, 0)
    static func clock(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let h = Int(parts[0]), h <= 23 else { return nil }
        var m = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let mm = Int(parts[1]), mm < 60 else { return nil }
            m = mm
        }
        return (h, m)
    }

    static func to24(_ h: Int, pm: Bool) -> Int {
        if pm { return h == 12 ? 12 : h + 12 }
        return h == 12 ? 0 : h
    }
}
