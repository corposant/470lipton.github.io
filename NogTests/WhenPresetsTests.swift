import XCTest
@testable import Nog

final class WhenPresetsTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// Published full moons (UTC), checked to the nearest few minutes.
    func testFullMoonsMatchPublishedTimes() {
        let known: [(after: Date, full: Date)] = [
            (date(2026, 11, 13), date(2026, 11, 24, 14, 53)),
            (date(2026, 11, 25), date(2026, 12, 24, 1, 28)),
            (date(2024, 1, 1), date(2024, 1, 25, 17, 54)),
            (date(2025, 9, 1), date(2025, 9, 7, 18, 9)),
        ]
        for (after, full) in known {
            let got = Moon.nextFull(after: after)
            XCTAssertEqual(got.timeIntervalSince1970, full.timeIntervalSince1970, accuracy: 10 * 60,
                           "full moon after \(after)")
        }
    }

    func testNextFullMoonStartsThatMorning() throws {
        let now = date(2026, 11, 13, 16, 42)
        let preset = try XCTUnwrap(WhenPresets.nextFullMoon(now: now, morningMinutes: 9 * 60, calendar: utc))
        XCTAssertEqual(preset.date, date(2026, 11, 24, 9))
        XCTAssertEqual(preset.label, "Next full moon")
        XCTAssertEqual(preset.spoken, "Next full moon, Tuesday, November 24")
    }

    /// On the full moon's own day, once its morning has gone, the next one is a month on.
    func testFullMoonDayAfterMorningSkipsToNextMonth() throws {
        let now = date(2026, 11, 24, 10)
        let preset = try XCTUnwrap(WhenPresets.nextFullMoon(now: now, morningMinutes: 9 * 60, calendar: utc))
        XCTAssertEqual(preset.date, date(2026, 12, 24, 9))
    }

    func testThreeWeeksBeforeChristmas() throws {
        let now = date(2026, 11, 13, 16, 42)
        let preset = try XCTUnwrap(WhenPresets.beforeChristmas(now: now, morningMinutes: 9 * 60, calendar: utc))
        XCTAssertEqual(preset.date, date(2026, 12, 4, 9))
        XCTAssertEqual(preset.label, "3 weeks before Xmas")
        XCTAssertEqual(preset.spoken, "Three weeks before Christmas, Friday, December 4")
    }

    /// Once December 4th's morning has passed it's too late to start three weeks out: no chip.
    func testChristmasPresetHidesOncePassed() {
        XCTAssertNil(WhenPresets.beforeChristmas(now: date(2026, 12, 4, 9, 30), morningMinutes: 9 * 60, calendar: utc))
        XCTAssertNotNil(WhenPresets.beforeChristmas(now: date(2027, 1, 2), morningMinutes: 9 * 60, calendar: utc))
    }
}
