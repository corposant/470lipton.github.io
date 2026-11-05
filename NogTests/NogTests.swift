import XCTest
@testable import Nog

final class ItemFileTests: XCTestCase {
    func testRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var item = Item(title: "Call the dentist: re crown", body: "Notes\n---\nsee [[Teeth]]")
        item.created = start
        item.updated = start
        item.parentID = UUID()
        item.tags = ["health", "calls"]
        item.reminder = Reminder(start: start, repeatMinutes: 8)

        let decoded = try XCTUnwrap(ItemFile.decode(ItemFile.encode(item)))
        XCTAssertEqual(decoded, item)
    }

    func testRoundTripEmptyBodyNoReminder() throws {
        var item = Item(title: "Idea")
        item.created = Date(timeIntervalSince1970: 1_800_000_000)
        item.updated = item.created
        let decoded = try XCTUnwrap(ItemFile.decode(ItemFile.encode(item)))
        XCTAssertEqual(decoded, item)
    }

    func testRejectsFilesWithoutHeader() {
        XCTAssertNil(ItemFile.decode("just some text"))
        XCTAssertNil(ItemFile.decode("---\ntitle: no id\n---\n"))
    }
}

final class LinkParserTests: XCTestCase {
    func testLinks() {
        XCTAssertEqual(LinkParser.links(in: "see [[Alpha]] and [[beta|B]] and [[alpha]] [[ ]] [[unclosed"),
                       ["Alpha", "beta"])
    }
}

final class CaptureParserTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)

    func testDefaultsApply() {
        let r = CaptureParser.parse("call mom", defaults: defaults, now: now)
        XCTAssertEqual(r.title, "Call mom")
        XCTAssertEqual(r.reminder, Reminder(start: now.addingTimeInterval(15 * 60), repeatMinutes: 8))
    }

    func testOverrides() {
        let r = CaptureParser.parse("pay rent !2h @1d #money", defaults: defaults, now: now)
        XCTAssertEqual(r.title, "Pay rent")
        XCTAssertEqual(r.tags, ["money"])
        XCTAssertEqual(r.reminder, Reminder(start: now.addingTimeInterval(86_400), repeatMinutes: 120))
    }

    func testOffAndOnce() {
        XCTAssertNil(CaptureParser.parse("app idea !off", defaults: defaults, now: now).reminder)
        XCTAssertNil(CaptureParser.parse("x !once", defaults: defaults, now: now).reminder?.repeatMinutes)
    }

    func testNonTokensStayInTitle() {
        let r = CaptureParser.parse("meet @home !important wow!", defaults: defaults, now: now)
        XCTAssertEqual(r.title, "Meet @home !important wow!")
    }
}

final class NogPlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ title: String, startOffset: TimeInterval, every: Int?, status: ItemStatus = .open) -> Item {
        Item(title: title, status: status,
             reminder: Reminder(start: now.addingTimeInterval(startOffset), repeatMinutes: every))
    }

    func testActiveItemGetsOneRepeatingTrigger() {
        let plan = NogPlanner.plan(items: [item("a", startOffset: -600, every: 8)], now: now)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.trigger, .every(480))
    }

    func testFutureItemGetsStartPlusFollowUps() {
        let plan = NogPlanner.plan(items: [item("a", startOffset: 600, every: 8)], now: now, maxFollowUpsPerItem: 3)
        XCTAssertEqual(plan.map(\.fireDate), [600, 1080, 1560, 2040].map { now.addingTimeInterval($0) })
    }

    func testDoneAndPastOneShotsAreSkipped() {
        let plan = NogPlanner.plan(items: [
            item("done", startOffset: -60, every: 8, status: .done),
            item("past once", startOffset: -60, every: nil),
        ], now: now)
        XCTAssertTrue(plan.isEmpty)
    }

    func testBudgetPrefersEveryItemsFirstNog() {
        let items = (0..<10).map { item("i\($0)", startOffset: Double($0 + 1) * 60, every: 1) }
        let plan = NogPlanner.plan(items: items, now: now, budget: 12)
        XCTAssertEqual(plan.count, 12)
        XCTAssertEqual(Set(plan.map(\.itemID)).count, 10)
    }

    func testIdentifiersAreStable() {
        let a = item("a", startOffset: -600, every: 8)
        XCTAssertEqual(NogPlanner.plan(items: [a], now: now).map(\.identifier),
                       NogPlanner.plan(items: [a], now: now.addingTimeInterval(1000)).map(\.identifier))
    }
}

@MainActor
final class ItemStoreTests: XCTestCase {
    func testPersistsAndReloads() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ItemStore(folder: folder, schedulesNotifications: false)
        let parent = try XCTUnwrap(store.capture("Project"))
        let child = try XCTUnwrap(store.capture("Step one !off", parent: parent.id))
        store.markDone(child.id)
        store.flushForTesting()

        let reloaded = ItemStore(folder: folder, schedulesNotifications: false)
        XCTAssertEqual(reloaded.items.count, 2)
        XCTAssertEqual(reloaded.children(of: parent.id).map(\.id), [child.id])
        XCTAssertEqual(reloaded.items[child.id]?.status, .done)
        XCTAssertNotNil(reloaded.items[child.id]?.completed)
    }
}

final class NaturalDateParserTests: XCTestCase {
    // Thursday, 5 Nov 2026, 10:00 UTC
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    lazy var now = date(2026, 11, 5, 10, 0)

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func parse(_ text: String) -> ParsedWhen {
        NaturalDateParser.parse(text, now: now, calendar: calendar)
    }

    func check(_ text: String, _ title: String, _ start: Date?, repeat minutes: Int? = nil,
               file: StaticString = #filePath, line: UInt = #line) {
        let r = parse(text)
        XCTAssertEqual(r.title, title, "title for '\(text)'", file: file, line: line)
        XCTAssertEqual(r.start, start, "start for '\(text)'", file: file, line: line)
        XCTAssertEqual(r.repeatMinutes, minutes, "repeat for '\(text)'", file: file, line: line)
    }

    func testExamples() {
        check("lunch next Tues", "Lunch", date(2026, 11, 10, 12, 0))
        check("call mom tomorrow at 3", "Call mom", date(2026, 11, 6, 15, 0))
        check("pay rent friday", "Pay rent", date(2026, 11, 6, 9, 0))
        check("dentist nov 12 at 2:30pm", "Dentist", date(2026, 11, 12, 14, 30))
        check("dentist 12th of november 9am", "Dentist", date(2026, 11, 12, 9, 0))
        check("take pills every 4 hours", "Take pills", nil, repeat: 240)
        check("stretch in 20 min", "Stretch", now.addingTimeInterval(20 * 60))
        check("stretch in 2h", "Stretch", now.addingTimeInterval(2 * 3600))
        check("stretch in half an hour", "Stretch", now.addingTimeInterval(1800))
        check("submit report by eod", "Submit report", date(2026, 11, 5, 17, 0))
        check("dinner with Sam on sat", "Dinner with Sam", date(2026, 11, 7, 18, 30))
        check("dinner with Sam at 7 tomorrow", "Dinner with Sam", date(2026, 11, 6, 19, 0))
        check("call bank at 9am", "Call bank", date(2026, 11, 6, 9, 0)) // 9am already passed today
        check("call bank at 4pm", "Call bank", date(2026, 11, 5, 16, 0))
        check("standup tomorrow morning", "Standup", date(2026, 11, 6, 9, 0))
        check("water plants this evening", "Water plants", date(2026, 11, 5, 18, 0))
        check("plan trip next week", "Plan trip", date(2026, 11, 9, 9, 0))
        check("taxes jan 15", "Taxes", date(2027, 1, 15, 9, 0))
        check("thursday thing", "Thing", date(2026, 11, 12, 9, 0))
        check("check oven every 10 min", "Check oven", nil, repeat: 10)
    }

    func testLeavesOrdinaryTextAlone() {
        check("morning run", "Morning run", nil)
        check("meet in park", "Meet in park", nil)
        check("read 3 books", "Read 3 books", nil)
        check("sat on the couch", "Sat on the couch", nil)
        check("may need milk", "May need milk", nil)
    }

    func testCaptureUsesNaturalDates() {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)
        let r = CaptureParser.parse("lunch next Tues #food", defaults: defaults, now: now, calendar: calendar)
        XCTAssertEqual(r.title, "Lunch")
        XCTAssertEqual(r.tags, ["food"])
        XCTAssertEqual(r.reminder, Reminder(start: date(2026, 11, 10, 12, 0), repeatMinutes: 8))
    }
}
