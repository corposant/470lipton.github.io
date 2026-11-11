import XCTest
@testable import Nog

/// Things that come back after they're done: meds every morning, bins every Tuesday.
final class RecurrenceTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // Thursday, 5 Nov 2026, 10:00 UTC
    lazy var now = date(2026, 11, 5, 10, 0)

    func parse(_ text: String) -> ParsedWhen {
        NaturalDateParser.parse(text, now: now, calendar: calendar)
    }

    func check(_ text: String, _ title: String, _ start: Date, _ rule: Recurrence.Rule,
               file: StaticString = #filePath, line: UInt = #line) {
        let r = parse(text)
        XCTAssertEqual(r.title, title, "title for '\(text)'", file: file, line: line)
        XCTAssertEqual(r.start, start, "start for '\(text)'", file: file, line: line)
        XCTAssertEqual(r.recurrence, Recurrence(rule), "rule for '\(text)'", file: file, line: line)
        XCTAssertNil(r.repeatMinutes, "nog rhythm for '\(text)'", file: file, line: line)
    }

    func testParsesThingsThatComeBack() {
        check("meds every morning", "Meds", date(2026, 11, 6, 9, 0), .days(1))
        check("meds daily at 8pm", "Meds", date(2026, 11, 5, 20, 0), .days(1))
        check("bins every tue", "Bins", date(2026, 11, 10, 9, 0), .weekdays([3]))
        check("gym every mon and thu at 6pm", "Gym", date(2026, 11, 5, 18, 0), .weekdays([2, 5]))
        check("rent every month on the 1st", "Rent", date(2026, 12, 1, 9, 0), .monthly(day: 1))
        check("water plants every 2 days", "Water plants", date(2026, 11, 6, 9, 0), .days(2))
        check("standup every weekday at 9:30am", "Standup", date(2026, 11, 6, 9, 30),
              .weekdays(Recurrence.weekdaysOnly))
        check("review budget every week", "Review budget", date(2026, 11, 6, 9, 0), .weeks(1))
    }

    func testShortRepeatsStillMeanHowOftenToNog() {
        let r = parse("take pills every 4 hours")
        XCTAssertEqual(r.repeatMinutes, 240)
        XCTAssertNil(r.recurrence)
    }

    func testNextAfterDone() {
        let daily = Recurrence(.days(1))
        XCTAssertEqual(daily.next(after: date(2026, 11, 5, 8, 5), from: date(2026, 11, 5, 8, 0), calendar: calendar),
                       date(2026, 11, 6, 8, 0))
        // Done early, before it was due: still the next one.
        XCTAssertEqual(daily.next(after: date(2026, 11, 5, 7, 0), from: date(2026, 11, 5, 8, 0), calendar: calendar),
                       date(2026, 11, 6, 8, 0))
        // Three days late: the next one still ahead, not one in the past.
        XCTAssertEqual(daily.next(after: date(2026, 11, 5, 10, 0), from: date(2026, 11, 1, 8, 0), calendar: calendar),
                       date(2026, 11, 6, 8, 0))

        let tuesdays = Recurrence(.weekdays([3]))
        XCTAssertEqual(tuesdays.next(after: date(2026, 11, 10, 9, 30), from: date(2026, 11, 10, 9, 0), calendar: calendar),
                       date(2026, 11, 17, 9, 0))

        let fortnightly = Recurrence(.weeks(2))
        XCTAssertEqual(fortnightly.next(after: date(2026, 11, 5, 10, 0), from: date(2026, 11, 5, 9, 0), calendar: calendar),
                       date(2026, 11, 19, 9, 0))

        // The 31st in a short month is its last day.
        let monthEnd = Recurrence(.monthly(day: 31))
        XCTAssertEqual(monthEnd.next(after: date(2027, 1, 31, 9, 5), from: date(2027, 1, 31, 9, 0), calendar: calendar),
                       date(2027, 2, 28, 9, 0))
    }

    func testAlignsTheFirstTime() {
        XCTAssertEqual(Recurrence(.weekdays([3])).aligned(date(2026, 11, 5, 9, 0), calendar: calendar),
                       date(2026, 11, 10, 9, 0))
        XCTAssertEqual(Recurrence(.monthly(day: 1)).aligned(date(2026, 11, 5, 9, 0), calendar: calendar),
                       date(2026, 12, 1, 9, 0))
        XCTAssertEqual(Recurrence(.days(1)).aligned(date(2026, 11, 5, 9, 0), calendar: calendar),
                       date(2026, 11, 5, 9, 0))
    }

    func testFileRoundTrip() throws {
        for rule: Recurrence.Rule in [.days(1), .days(3), .weekdays([2, 4, 6]), .weeks(2), .monthly(day: 15),
                                      .yearly(month: 11, day: 12)] {
            XCTAssertEqual(Recurrence(encoded: Recurrence(rule).encoded), Recurrence(rule))
        }
        var item = Item(title: "Meds")
        item.created = Date(timeIntervalSince1970: 1_800_000_000)
        item.updated = item.created
        item.reminder = Reminder(start: item.created, repeatMinutes: 8)
        item.recurrence = Recurrence(.days(1))
        item.lastDone = item.created
        item.timesDone = 4
        XCTAssertEqual(try XCTUnwrap(ItemFile.decode(ItemFile.encode(item))), item)
    }

    func testSummaries() {
        XCTAssertEqual(Recurrence(.days(1)).summary, "every day")
        XCTAssertEqual(Recurrence(.weekdays(Recurrence.weekdaysOnly)).summary, "every weekday")
        XCTAssertEqual(Recurrence(.monthly(day: 1)).summary, "monthly on the 1st")
        XCTAssertEqual(Recurrence(.weeks(2)).summary, "every other week")
    }
}

/// "When I get home", "when I leave work".
final class PlacePhraseTests: XCTestCase {
    func extract(_ text: String, known: [String] = []) -> (PlaceTrigger, String)? {
        let words = text.split(separator: " ").map(String.init)
        return PlacePhraseParser.extract(from: words, known: known).map { ($0.0, $0.1.joined(separator: " ")) }
    }

    func testFindsPlaces() {
        XCTAssertEqual(extract("take out bins when I get home")?.0, PlaceTrigger(name: "Home"))
        XCTAssertEqual(extract("take out bins when I get home")?.1, "take out bins")
        XCTAssertEqual(extract("print forms when I get to work")?.0, PlaceTrigger(name: "Work"))
        XCTAssertEqual(extract("buy milk when I leave work")?.0, PlaceTrigger(name: "Work", leaving: true))
        XCTAssertEqual(extract("return book when I'm at the library")?.0, PlaceTrigger(name: "The library"))
        XCTAssertEqual(extract("hug when I arrive at mum's", known: ["Mum's"])?.0, PlaceTrigger(name: "Mum's"))
    }

    func testLeavesOtherWhensAlone() {
        XCTAssertNil(extract("call me when I get paid"))
        XCTAssertNil(extract("ask when the party is"))
        XCTAssertNil(extract("text Sam when I get a chance"))
    }

    func testCaptureWaitsForThePlace() {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8, places: ["Home"])
        let result = CaptureParser.parse("bins when I get home", defaults: defaults, now: .now)
        XCTAssertEqual(result.title, "Bins")
        XCTAssertEqual(result.place, PlaceTrigger(name: "Home"))
        XCTAssertNil(result.reminder)
    }
}
