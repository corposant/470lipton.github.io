import Foundation

/// The seasonal and lunar picks in New Nog's When panel. Like every When, these are when
/// nogging *starts*, not a deadline: "3 weeks before Xmas" starts nudging you well ahead of the day.
enum WhenPresets {
    /// One suggested start time: what the chip says, and what VoiceOver says (with the date).
    struct Preset: Equatable {
        var label: String
        var spoken: String
        var date: Date
    }

    /// Three weeks before Christmas (December 4) at your morning time, while that's still ahead this year.
    static func beforeChristmas(now: Date, morningMinutes: Int = NogSettings.morningMinutes,
                                calendar: Calendar = .current) -> Preset? {
        let year = calendar.component(.year, from: now)
        guard let christmas = calendar.date(from: DateComponents(year: year, month: 12, day: 25)),
              let day = calendar.date(byAdding: .day, value: -21, to: christmas),
              let start = at(morningMinutes, on: day, calendar: calendar),
              start > now else { return nil }
        return Preset(label: "3 weeks before Xmas",
                      spoken: "Three weeks before Christmas, \(spokenDate(start, calendar: calendar))",
                      date: start)
    }

    /// The morning of the next full moon (worked out on the phone, no network).
    static func nextFullMoon(now: Date, morningMinutes: Int = NogSettings.morningMinutes,
                             calendar: Calendar = .current) -> Preset? {
        var k = (Moon.lunation(at: now) - 1).rounded(.down) + 0.5
        // A few steps at most: the first full moon whose morning is still ahead.
        for _ in 0..<4 {
            let moon = Moon.fullMoon(k)
            if let start = at(morningMinutes, on: moon, calendar: calendar), start > now {
                return Preset(label: "Next full moon",
                              spoken: "Next full moon, \(spokenDate(start, calendar: calendar))",
                              date: start)
            }
            k += 1
        }
        return nil
    }

    /// `minutes` after midnight on `day`'s calendar day.
    private static func at(_ minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    /// "Friday, December 4" (no year; these are never more than a year off).
    private static func spokenDate(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if let locale = calendar.locale { style.locale = locale }
        return date.formatted(style)
    }
}

/// Full moons from Meeus, *Astronomical Algorithms* (ch. 49), main periodic terms:
/// within a few minutes for centuries either side of 2000, which is plenty to pick a day.
enum Moon {
    /// Mean length of a lunar month in days.
    static let synodicMonth = 29.530588861
    /// The mean new moon of 6 Jan 2000 (lunation 0), as a Julian Ephemeris Day.
    private static let epochJDE = 2451550.09766

    /// Lunations since January 2000's new moon at `date` (fractional; full moons sit at n + 0.5).
    static func lunation(at date: Date) -> Double {
        (julianDay(date) - epochJDE) / synodicMonth
    }

    /// The full moon of lunation `k` (k must end in .5).
    static func fullMoon(_ k: Double) -> Date {
        let t = k / 1236.85
        let t2 = t * t, t3 = t2 * t, t4 = t3 * t
        var jde = epochJDE + synodicMonth * k + 0.00015437 * t2 - 0.000000150 * t3 + 0.00000000073 * t4
        let e = 1 - 0.002516 * t - 0.0000074 * t2
        func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
        let m = rad(2.5534 + 29.10535670 * k - 0.0000014 * t2 - 0.00000011 * t3)
        let mp = rad(201.5643 + 385.81693528 * k + 0.0107582 * t2 + 0.00001238 * t3 - 0.000000058 * t4)
        let f = rad(160.7108 + 390.67050284 * k - 0.0016118 * t2 - 0.00000227 * t3 + 0.000000011 * t4)
        let omega = rad(124.7746 - 1.56375588 * k + 0.0020672 * t2 + 0.00000215 * t3)
        jde += -0.40614 * sin(mp)
            + 0.17302 * e * sin(m)
            + 0.01614 * sin(2 * mp)
            + 0.01043 * sin(2 * f)
            + 0.00734 * e * sin(mp - m)
            - 0.00515 * e * sin(mp + m)
            + 0.00209 * e * e * sin(2 * m)
            - 0.00111 * sin(mp - 2 * f)
            - 0.00057 * sin(mp + 2 * f)
            + 0.00056 * e * sin(2 * mp + m)
            - 0.00042 * sin(3 * mp)
            + 0.00042 * e * sin(m + 2 * f)
            + 0.00038 * e * sin(m - 2 * f)
            - 0.00024 * e * sin(2 * mp - m)
            - 0.00017 * sin(omega)
        return Date(timeIntervalSince1970: (jde - 2440587.5) * 86400)
    }

    /// The first full moon after `date`.
    static func nextFull(after date: Date) -> Date {
        var k = (lunation(at: date) - 1).rounded(.down) + 0.5
        while fullMoon(k) <= date { k += 1 }
        return fullMoon(k)
    }

    private static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2440587.5
    }
}
