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

    func testRoundTripPosition() throws {
        var item = Item(title: "Step")
        item.created = Date(timeIntervalSince1970: 1_800_000_000)
        item.updated = item.created
        item.parentID = UUID()
        item.position = 3
        let decoded = try XCTUnwrap(ItemFile.decode(ItemFile.encode(item)))
        XCTAssertEqual(decoded.position, 3)
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

    // MARK: "Open Nog to keep nogging"

    func testPauseNoticeComesJustAfterTheLastLinedUpNog() throws {
        let a = item("a", startOffset: 600, every: 8)
        let plan = NogPlanner.plan(items: [a], now: now, maxFollowUpsPerItem: 3)
        let notice = try XCTUnwrap(NogPlanner.pauseNotice(for: plan, items: [a], now: now))
        XCTAssertEqual(notice.fireDate, now.addingTimeInterval(2040 + 60))
        XCTAssertEqual(notice.category, NogPlanner.categoryPause)
        XCTAssertTrue(notice.identifier.hasPrefix(NogPlanner.prefix), "so sync replaces and clears it")
    }

    func testPauseNoticeFollowsTheItemThatRunsOutFirst() throws {
        let soon = item("soon", startOffset: 60, every: 1)
        let later = item("later", startOffset: 3600, every: 30)
        let plan = NogPlanner.plan(items: [soon, later], now: now, budget: 6)
        let notice = try XCTUnwrap(NogPlanner.pauseNotice(for: plan, items: [soon, later], now: now))
        let lastSoon = try XCTUnwrap(plan.filter { $0.itemID == soon.id }.compactMap(\.fireDate).max())
        XCTAssertEqual(notice.fireDate, lastSoon.addingTimeInterval(60))
    }

    func testNoPauseNoticeWhenEverythingRepeatsOnItsOwn() {
        let a = item("a", startOffset: -600, every: 8)
        let plan = NogPlanner.plan(items: [a], now: now)
        XCTAssertNil(NogPlanner.pauseNotice(for: plan, items: [a], now: now))
    }

    func testNoPauseNoticeForOneOffReminders() {
        let once = item("once", startOffset: 600, every: nil)
        let plan = NogPlanner.plan(items: [once], now: now)
        XCTAssertNil(NogPlanner.pauseNotice(for: plan, items: [once], now: now))
    }

    func testPauseNoticeWaitsForQuietHoursToEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // `now` is 08:00 UTC. Nogs at 08:06, 08:14, 08:22 are lined up; quiet runs 08:23 to 11:23.
        let a = item("a", startOffset: -600, every: 8)
        var policy = NogPolicy.standard
        policy.quiet = QuietHours(enabled: true, start: 8 * 60 + 23, end: 11 * 60 + 23)
        let plan = NogPlanner.plan(items: [a], now: now, maxFollowUpsPerItem: 2, policy: policy, calendar: calendar)
        XCTAssertEqual(plan.compactMap(\.fireDate), [360, 840, 1320].map { now.addingTimeInterval($0) })
        let notice = try XCTUnwrap(NogPlanner.pauseNotice(for: plan, items: [a], now: now, policy: policy, calendar: calendar))
        XCTAssertEqual(notice.fireDate, now.addingTimeInterval((3 * 60 + 23) * 60))
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

    func testReorderedMatchesOnMove() {
        let items = ["A", "B", "C", "D"].map { Item(title: $0) }
        let titles = { (from: IndexSet, to: Int) in Item.reordered(items, from: from, to: to).map(\.title) }
        XCTAssertEqual(titles([0], 2), ["B", "A", "C", "D"])
        XCTAssertEqual(titles([3], 0), ["D", "A", "B", "C"])
        XCTAssertEqual(titles([1], 4), ["A", "C", "D", "B"])
        XCTAssertEqual(titles([0, 2], 4), ["B", "D", "A", "C"])
        XCTAssertEqual(titles([2], 2), ["A", "B", "C", "D"])
    }

    func testSubNogOrderPersistsAndNewOnesGoLast() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ItemStore(folder: folder, schedulesNotifications: false)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let parent = try XCTUnwrap(store.capture("Oil change", now: t0))
        let a = try XCTUnwrap(store.capture("Buy oil", parent: parent.id, now: t0.addingTimeInterval(1)))
        let b = try XCTUnwrap(store.capture("Buy filter", parent: parent.id, now: t0.addingTimeInterval(2)))
        let c = try XCTUnwrap(store.capture("Book the lift", parent: parent.id, now: t0.addingTimeInterval(3)))

        store.moveChildren(of: parent.id, from: [2], to: 0)
        XCTAssertEqual(store.children(of: parent.id).map(\.id), [c.id, a.id, b.id])

        let d = try XCTUnwrap(store.capture("Crush washer", parent: parent.id, now: t0.addingTimeInterval(4)))
        XCTAssertEqual(store.children(of: parent.id).map(\.id), [c.id, a.id, b.id, d.id])

        // VoiceOver's Move down / Move up
        let place = try XCTUnwrap(store.moveChild(c.id, by: 1))
        XCTAssertEqual(place.place, 2)
        XCTAssertEqual(place.of, 4)
        XCTAssertNil(store.moveChild(c.id, by: -2))
        XCTAssertNil(store.moveChild(d.id, by: 1))
        XCTAssertEqual(store.children(of: parent.id).map(\.id), [a.id, c.id, b.id, d.id])

        store.flushForTesting()
        let reloaded = ItemStore(folder: folder, schedulesNotifications: false)
        XCTAssertEqual(reloaded.children(of: parent.id).map(\.id), [a.id, c.id, b.id, d.id])
    }

    func testMovingToAnotherParentForgetsOldPlace() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ItemStore(folder: folder, schedulesNotifications: false)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try XCTUnwrap(store.capture("First", now: t0))
        let second = try XCTUnwrap(store.capture("Second", now: t0))
        let a = try XCTUnwrap(store.capture("A", parent: first.id, now: t0.addingTimeInterval(1)))
        let b = try XCTUnwrap(store.capture("B", parent: first.id, now: t0.addingTimeInterval(2)))
        _ = try XCTUnwrap(store.capture("Old", parent: second.id, now: t0.addingTimeInterval(3)))
        store.moveChildren(of: first.id, from: [1], to: 0)
        XCTAssertEqual(store.items[b.id]?.position, 0)

        var moved = try XCTUnwrap(store.items[b.id])
        moved.parentID = second.id
        store.update(moved)
        XCTAssertNil(store.items[b.id]?.position)
        XCTAssertEqual(store.children(of: second.id).last?.id, b.id)
        XCTAssertEqual(store.children(of: first.id).map(\.id), [a.id])
    }

    func testUnreadableFolderIsNotMistakenForAnEmptyOne() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertFalse(FileStorage.readAllNow(in: missing, coordinated: false).folderReadable)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        XCTAssertTrue(FileStorage.readAllNow(in: missing, coordinated: false).folderReadable)
    }
}

final class IncrementalReadTests: XCTestCase {
    func testOnlyChangedFilesAreReadAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let items = (0..<3).map { Item(title: "Item \($0)") }
        for item in items {
            try ItemFile.encode(item).write(to: folder.appending(path: "\(item.id.uuidString).md"), atomically: true, encoding: .utf8)
        }
        var cache = FileStorage.FileCache()

        let first = FileStorage.readAllNow(in: folder, coordinated: false, cache: &cache)
        XCTAssertEqual(first.filesRead, 3)
        XCTAssertEqual(first.items.count, 3)

        let unchanged = FileStorage.readAllNow(in: folder, coordinated: false, cache: &cache)
        XCTAssertEqual(unchanged.filesRead, 0)
        XCTAssertEqual(Set(unchanged.items.map(\.id)), Set(items.map(\.id)))

        var edited = items[1]
        edited.title = "Item one, renamed"
        let url = folder.appending(path: "\(edited.id.uuidString).md")
        try ItemFile.encode(edited).write(to: url, atomically: true, encoding: .utf8)
        // Make sure the edit doesn't land in the same instant as the first write.
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: url.path)

        let afterEdit = FileStorage.readAllNow(in: folder, coordinated: false, cache: &cache)
        XCTAssertEqual(afterEdit.filesRead, 1)
        XCTAssertEqual(afterEdit.items.first { $0.id == edited.id }?.title, "Item one, renamed")

        try FileManager.default.removeItem(at: folder.appending(path: "\(items[0].id.uuidString).md"))
        let afterDelete = FileStorage.readAllNow(in: folder, coordinated: false, cache: &cache)
        XCTAssertEqual(afterDelete.items.count, 2)
        XCTAssertEqual(afterDelete.filesRead, 0)
    }

    func testOnlyNogFieldsTriggerRescheduling() {
        let item = Item(title: "Water plants", reminder: Reminder(start: .now, repeatMinutes: 30))
        var notes = item
        notes.body = "the ferns too"
        notes.tags = ["home"]
        XCTAssertFalse(notes.changesNogs(from: item))

        var renamed = item
        renamed.title = "Water the plants"
        XCTAssertTrue(renamed.changesNogs(from: item))

        var moved = item
        moved.reminder?.repeatMinutes = 60
        XCTAssertTrue(moved.changesNogs(from: item))
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

final class LogarithmicReminderTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    var log8: Reminder { Reminder(start: start, repeatMinutes: 8, curve: .logarithmic) }

    func testGapsDoubleThenCapAtADay() {
        let gaps = (0..<10).map { log8.gap(after: $0)! / 60 }
        XCTAssertEqual(gaps, [8, 16, 32, 64, 128, 256, 512, 1024, 1440, 1440])
    }

    func testFireDates() {
        XCTAssertEqual(log8.fireDates(after: minutes(-1), limit: 5),
                       [0, 8, 24, 56, 120].map(minutes))
        XCTAssertEqual(log8.fireDates(after: minutes(10), limit: 2), [24, 56].map(minutes))
    }

    func testSettlesOnceTheGapReachesADay() {
        let settled = try! XCTUnwrap(log8.settledPhase)
        XCTAssertEqual(settled.since, minutes(8 + 16 + 32 + 64 + 128 + 256 + 512 + 1024))
        XCTAssertEqual(settled.gap, 86_400)
        // Fires continue daily after settling.
        let after = log8.fireDates(after: settled.since, limit: 2)
        XCTAssertEqual(after, [settled.since.addingTimeInterval(86_400), settled.since.addingTimeInterval(172_800)])
    }

    func testSteadyFireDatesJumpAhead() {
        let steady = Reminder(start: start, repeatMinutes: 1)
        XCTAssertEqual(steady.fireDates(after: minutes(100_000.5), limit: 1), [minutes(100_001)])
    }

    func testPlannerUsesOneShotsWhileEasingOffAndRepeatsOnceSettled() {
        let easing = Item(title: "a", reminder: log8)
        let plan = NogPlanner.plan(items: [easing], now: minutes(10), maxFollowUpsPerItem: 2)
        XCTAssertEqual(plan.map(\.fireDate), [24, 56, 120].map(minutes))

        // Settled at a day: a daily trigger at the item's own time of day, not "a day from now".
        let settledPlan = NogPlanner.plan(items: [easing], now: minutes(5000))
        let next = try! XCTUnwrap(log8.nextFire(after: minutes(5000)))
        let time = Calendar.current.dateComponents([.hour, .minute], from: next)
        XCTAssertEqual(settledPlan.map(\.trigger), [.daily(hour: time.hour!, minute: time.minute!)])
    }

    func testDailyKeepsItsTimeAndEveryOtherDayUsesExactTimes() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let daily = Item(title: "meds", reminder: Reminder(start: now.addingTimeInterval(-3 * 86_400 + 1800), repeatMinutes: 1440))
        let plan = NogPlanner.plan(items: [daily], now: now)
        let time = Calendar.current.dateComponents([.hour, .minute], from: now.addingTimeInterval(1800))
        XCTAssertEqual(plan.map(\.trigger), [.daily(hour: time.hour!, minute: time.minute!)])

        let tea = Item(title: "call grandma", reminder: NogProfile.teatime.apply(to: Reminder(start: now.addingTimeInterval(-86_400))))
        let teaPlan = NogPlanner.plan(items: [tea], now: now, maxFollowUpsPerItem: 3)
        XCTAssertEqual(teaPlan.map(\.fireDate), [1, 3, 5, 7].map { now.addingTimeInterval(Double($0) * 86_400) })
    }

    func testTeatimeNeverNogsEveryMinute() {
        XCTAssertEqual(NogProfile.teatime.repeatMinutes, 2880)
        XCTAssertEqual(NogProfile.matching(NogProfile.teatime.reminder(from: .now)), .teatime)
    }

    func testCaptureTokenAndFileRoundTrip() throws {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)
        let parsed = CaptureParser.parse("water plants !log", defaults: defaults, now: start)
        XCTAssertEqual(parsed.title, "Water plants")
        XCTAssertEqual(parsed.reminder?.curve, .logarithmic)

        var item = Item(title: "x", reminder: log8)
        item.created = start
        item.updated = start
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item)), item)
    }
}

final class AlarmHandoffTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNotificationsSkipTimesThatRingAsAlarms() {
        let item = Item(title: "meds", reminder: Reminder(start: now.addingTimeInterval(-600), repeatMinutes: 10, alarm: true))
        let alarms = AlarmScheduler.alarmDates(for: item, policy: .standard, now: now, limit: 5)
        XCTAssertEqual(alarms.count, 5)
        let plan = NogPlanner.plan(items: [item], now: now, maxFollowUpsPerItem: 1, alarmDates: [item.id: alarms])
        XCTAssertEqual(plan.compactMap(\.fireDate).count, 2)
        XCTAssertTrue(plan.allSatisfy { ($0.fireDate ?? .distantPast) > alarms.last! })
    }

    func testEscalationRingsAfterIgnoredNogs() {
        var policy = NogPolicy.standard
        policy.escalateAfter = 3
        let start = now.addingTimeInterval(-60)
        let item = Item(title: "taxes", reminder: Reminder(start: start, repeatMinutes: 10))
        let alarms = AlarmScheduler.alarmDates(for: item, policy: policy, now: now, limit: 2)
        // Nogs at start, +10, +20 are ignored; the one at +30 rings.
        XCTAssertEqual(alarms, [start.addingTimeInterval(1800), start.addingTimeInterval(2400)])
        XCTAssertTrue(AlarmScheduler.alarmDates(for: item, policy: .standard, now: now).isEmpty)
    }

    func testAlarmTokenAndRoundTrip() throws {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)
        let parsed = CaptureParser.parse("take meds 9pm !alarm", defaults: defaults, now: now)
        XCTAssertEqual(parsed.reminder?.alarm, true)

        var item = Item(title: "x", reminder: Reminder(start: now, repeatMinutes: 5, alarm: true))
        item.created = now
        item.updated = now
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item)), item)
    }

    func testAlarmIDsAreStable() {
        let item = Item(title: "meds")
        XCTAssertEqual(AlarmScheduler.alarmID(item: item, date: now), AlarmScheduler.alarmID(item: item, date: now))
        XCTAssertNotEqual(AlarmScheduler.alarmID(item: item, date: now),
                          AlarmScheduler.alarmID(item: item, date: now.addingTimeInterval(60)))
    }
}

@MainActor
final class DoingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func doing(timebox: Int?, alarm: Bool = false) -> Item {
        var item = Item(title: "write", status: .doing,
                        reminder: Reminder(start: now.addingTimeInterval(-3600), repeatMinutes: 8, alarm: alarm))
        item.doingSince = now
        item.timeboxMinutes = timebox
        return item
    }

    func testStarterIsAlwaysTwoMinutes() {
        XCTAssertEqual(TimeboxAdvisor.suggest(defaultMinutes: 2), TimeboxSuggestion(minutes: 2, reason: "two-minute start"))
        XCTAssertEqual(TimeboxAdvisor.suggest(defaultMinutes: 0).minutes, NogSettings.defaultTimebox)
        XCTAssertEqual(NogSettings.defaultTimebox, 2)
    }

    func testStarterChimesThenChecksInWhileCountingUp() {
        let item = doing(timebox: 2)
        XCTAssertEqual(item.effectiveReminder, Reminder(start: now.addingTimeInterval(120), repeatMinutes: 15))
        XCTAssertFalse(item.isCountingUp(now: now.addingTimeInterval(119)))
        XCTAssertTrue(item.isCountingUp(now: now.addingTimeInterval(120)))

        let plan = NogPlanner.plan(items: [item], now: now.addingTimeInterval(30), maxFollowUpsPerItem: 1)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].fireDate, now.addingTimeInterval(120))
        XCTAssertTrue(plan[0].chime)
        XCTAssertEqual(plan[0].body, "Two minutes done. Keep going, or stop here. Both count.")
        XCTAssertEqual(plan[0].category, NogPlanner.categoryDoing)
        XCTAssertEqual(plan[1].fireDate, now.addingTimeInterval(120 + 15 * 60))
        XCTAssertFalse(plan[1].chime)
        XCTAssertEqual(plan[1].body, NogPlanner.checkInBody)
    }

    func testCheckInsCanBeChangedOrTurnedOffForOneSession() {
        var item = doing(timebox: 2)
        item.checkInMinutes = 30
        XCTAssertEqual(item.effectiveReminder?.repeatMinutes, 30)
        item.checkInMinutes = 0
        XCTAssertEqual(item.effectiveReminder, Reminder(start: now.addingTimeInterval(120), repeatMinutes: nil))
        XCTAssertEqual(NogPlanner.plan(items: [item], now: now).count, 1, "just the chime")
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item))?.checkInMinutes, 0)
    }

    func testTheChimeNeverRingsButUnhingedCheckInsDo() {
        let item = doing(timebox: 2, alarm: true)
        let dates = AlarmScheduler.alarmDates(for: item, policy: .standard, now: now, limit: 2)
        XCTAssertFalse(dates.contains(now.addingTimeInterval(120)))
        XCTAssertEqual(dates.first, now.addingTimeInterval(120 + 15 * 60))
    }

    func testStartFinishBanksTimeAndKeepsTheItem() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ItemStore(folder: folder, schedulesNotifications: false)
        let item = try XCTUnwrap(store.capture("write report"))
        XCTAssertEqual(store.suggestedTimebox(for: item.id).minutes, NogSettings.timeboxMinutes)

        store.start(item.id)
        XCTAssertEqual(store.items[item.id]?.status, .doing)
        XCTAssertEqual(store.items[item.id]?.timeboxMinutes, NogSettings.timeboxMinutes)
        XCTAssertNotNil(store.items[item.id]?.doingSince)

        store.setCheckIn(item.id, minutes: 30)
        XCTAssertEqual(store.items[item.id]?.checkInMinutes, 30)

        store.markDone(item.id)
        let finished = try XCTUnwrap(store.items[item.id])
        XCTAssertEqual(finished.status, .done)
        XCTAssertNil(finished.doingSince)
        XCTAssertNil(finished.checkInMinutes)
        XCTAssertNotNil(finished.completed)
        XCTAssertGreaterThanOrEqual(finished.timeSpent, 0)

        store.flushForTesting()
        let reloaded = ItemStore(folder: folder, schedulesNotifications: false)
        XCTAssertEqual(reloaded.items[item.id]?.status, .done)
    }

    func testDoneForNowLogsTimeAndGoesBackToOpen() throws {
        let store = ItemStore(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                              schedulesNotifications: false)
        let item = try XCTUnwrap(store.capture("sort the garage !off"))
        store.start(item.id)
        let logged = store.stopDoing(item.id, now: .now.addingTimeInterval(300))
        XCTAssertGreaterThanOrEqual(logged, 299)
        let stopped = try XCTUnwrap(store.items[item.id])
        XCTAssertEqual(stopped.status, .open)
        XCTAssertNil(stopped.doingSince)
        XCTAssertGreaterThanOrEqual(stopped.timeSpent, 0)
    }

    func testDoneForNowLeavesTheRestOfTodayAlone() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let afternoon = try XCTUnwrap(calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))

        // Nogging every 30 min since this morning: next nog moves to tomorrow morning.
        var item = Item(title: "taxes", reminder: Reminder(start: afternoon.addingTimeInterval(-4 * 3600), repeatMinutes: 30))
        let resume = try XCTUnwrap(ItemStore.resumeDate(for: item, now: afternoon, calendar: calendar))
        XCTAssertTrue(calendar.isDate(resume, inSameDayAs: tomorrow))
        XCTAssertEqual(resume, NogSettings.nextMorning(after: tomorrow.addingTimeInterval(-1)))

        // Once a day at 6 PM: back at 6 PM tomorrow, not in the morning.
        item.reminder = Reminder(start: afternoon.addingTimeInterval(4 * 3600), repeatMinutes: 1440)
        XCTAssertEqual(ItemStore.resumeDate(for: item, now: afternoon, calendar: calendar),
                       afternoon.addingTimeInterval(28 * 3600))

        // Urgent (rings like an alarm): keeps its rhythm.
        item.reminder = Reminder(start: afternoon, repeatMinutes: 30, alarm: true)
        XCTAssertNil(ItemStore.resumeDate(for: item, now: afternoon, calendar: calendar))

        // Flagged urgent: keeps its rhythm too.
        item.reminder = Reminder(start: afternoon, repeatMinutes: 30)
        item.urgent = true
        XCTAssertNil(ItemStore.resumeDate(for: item, now: afternoon, calendar: calendar))
        item.urgent = false

        // Nothing more today anyway: left alone.
        item.reminder = Reminder(start: tomorrow.addingTimeInterval(3600), repeatMinutes: 30)
        XCTAssertNil(ItemStore.resumeDate(for: item, now: afternoon, calendar: calendar))
    }

    func testUrgentFlagFromCaptureSavesAndSortsFirst() throws {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)
        let flagged = CaptureParser.parse("renew passport !urgent", defaults: defaults, now: now)
        XCTAssertEqual(flagged.title, "renew passport")
        XCTAssertTrue(flagged.urgent)
        XCTAssertTrue(CaptureParser.parse("call vet !! !off", defaults: defaults, now: now).urgent)
        XCTAssertFalse(CaptureParser.parse("call vet", defaults: defaults, now: now).urgent)

        var item = Item(title: "renew passport")
        item.urgent = true
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item))?.urgent, true)

        let calm = Item(title: "a", created: now)
        let sorted = [calm, item].sorted { Item.urgentFirst($0, $1) { $0.created < $1.created } }
        XCTAssertEqual(sorted.first?.id, item.id)
    }

    func testStartOnANogWithSubNogsStartsItsFirstUnfinishedStep() throws {
        let store = ItemStore(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                              schedulesNotifications: false)
        let parent = try XCTUnwrap(store.capture("do the oil change !off"))
        let first = try XCTUnwrap(store.capture("check sales on oil !off", parent: parent.id))
        let second = try XCTUnwrap(store.capture("buy filter !off", parent: parent.id))
        store.markDone(first.id)

        XCTAssertEqual(store.startTarget(for: parent.id), second.id)
        store.start(parent.id)
        XCTAssertEqual(store.items[second.id]?.status, .doing)
        XCTAssertEqual(store.items[parent.id]?.status, .open)
        XCTAssertEqual(store.doingDescendant(of: parent.id)?.id, second.id)

        // Pressing ▶︎ on the parent again leaves the running step's timer alone.
        let since = store.items[second.id]?.doingSince
        store.start(parent.id, timebox: 25)
        XCTAssertEqual(store.items[second.id]?.doingSince, since)
        XCTAssertEqual(store.items[second.id]?.timeboxMinutes, NogSettings.timeboxMinutes)
    }
}

@MainActor
final class ReviewFixTests: XCTestCase {
    func makeStore() -> ItemStore {
        ItemStore(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                  schedulesNotifications: false)
    }

    func testRemindersSetForNowStillFire() throws {
        let store = makeStore()
        let once = try XCTUnwrap(store.capture("call bank @now !once"))
        let saved = try XCTUnwrap(store.items[once.id]?.reminder)
        XCTAssertGreaterThan(saved.start, .now, "a reminder set for now should fire in a moment, not never")
        XCTAssertFalse(NogPlanner.plan(items: Array(store.items.values), now: .now).isEmpty)
    }

    func testSnoozeWhileDoingAddsTimeInsteadOfStopping() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.capture("write report"))
        store.start(item.id, timebox: 25)
        store.snooze(item.id, until: .now.addingTimeInterval(600))
        XCTAssertEqual(store.items[item.id]?.status, .doing)
        XCTAssertEqual(store.items[item.id]?.timeboxMinutes, 35)
    }

    func testSnoozeDoesNotReopenFinishedItems() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.capture("done thing"))
        store.markDone(item.id)
        store.snooze(item.id, until: .now.addingTimeInterval(3600))
        XCTAssertEqual(store.items[item.id]?.status, .done)
    }

    func testDayOnlySiriDatesMeanNineAM() throws {
        let date = try XCTUnwrap(Calendar.nogDate(from: DateComponents(year: 2026, month: 11, day: 6)))
        XCTAssertEqual(Calendar.current.component(.hour, from: date), 9)
        let timed = try XCTUnwrap(Calendar.nogDate(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15)))
        XCTAssertEqual(Calendar.current.component(.hour, from: timed), 15)
    }
}

final class MapLayoutTests: XCTestCase {
    func testEdgesFromParentsAndLinks() {
        let parent = Item(title: "Trip")
        var child = Item(title: "Book flights")
        child.parentID = parent.id
        var note = Item(title: "Packing")
        note.body = "see [[trip]] and [[Nowhere]]"
        let edges = MapLayout.edges(for: [parent, child, note])
        XCTAssertTrue(edges.contains(.init(from: parent.id, to: child.id, kind: .parent)))
        XCTAssertTrue(edges.contains(.init(from: note.id, to: parent.id, kind: .link)))
        XCTAssertEqual(edges.count, 2)
    }

    func testLayoutKeepsPinnedNodesAndIsDeterministic() {
        let ids = (0..<12).map { _ in UUID() }
        let edges = (1..<12).map { MapLayout.Edge(from: ids[0], to: ids[$0], kind: .parent) }
        let pinned = [ids[0]: CGPoint(x: 40, y: -20)]
        let a = MapLayout.layout(ids: ids, edges: edges, pinned: pinned)
        let b = MapLayout.layout(ids: ids, edges: edges, pinned: pinned)
        XCTAssertEqual(a.count, 12)
        XCTAssertEqual(a[ids[0]], CGPoint(x: 40, y: -20))
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testOutlineTreeNestsAndSurvivesCycles() {
        var a = Item(title: "A")
        var b = Item(title: "B")
        b.parentID = a.id
        a.parentID = b.id // a cycle that should never crash the outline
        let c = Item(title: "C")
        let tree = OutlineView.tree([a, b, c], showNogged: false)
        func titles(_ nodes: [OutlineView.Node]) -> [String] {
            nodes.flatMap { [$0.item.title] + titles($0.children ?? []) }
        }
        XCTAssertEqual(Set(titles(tree)), ["A", "B", "C"])
        XCTAssertEqual(titles(tree).count, 3)
    }
}


final class PolicyTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    func testQuietHoursOvernight() {
        let quiet = QuietHours(enabled: true, start: 22 * 60, end: 7 * 60)
        XCTAssertTrue(quiet.contains(date(5, 23), calendar: calendar))
        XCTAssertTrue(quiet.contains(date(6, 6, 59), calendar: calendar))
        XCTAssertFalse(quiet.contains(date(6, 7), calendar: calendar))
        XCTAssertEqual(quiet.nextOpening(after: date(5, 23), calendar: calendar), date(6, 7))
        XCTAssertEqual(quiet.nextOpening(after: date(6, 12), calendar: calendar), date(6, 12))
    }

    func testQuietWeekendsSkipToMonday() {
        // Nov 7 2026 is a Saturday.
        let quiet = QuietHours(enabled: true, start: 22 * 60, end: 7 * 60, weekends: true)
        XCTAssertEqual(quiet.nextOpening(after: date(7, 12), calendar: calendar), date(9, 7))
    }

    func testPlannerPushesQuietNogsToMorningAndAddsHeadsUp() {
        let now = date(5, 21)
        var policy = NogPolicy.standard
        policy.quiet = QuietHours(enabled: true, start: 22 * 60, end: 7 * 60)
        policy.headsUpMinutes = 10

        // 11 PM is quiet: the nog waits for 7 AM, and its 10:50 PM heads-up is dropped.
        let late = Item(title: "late", reminder: Reminder(start: date(5, 23), repeatMinutes: nil))
        let latePlan = NogPlanner.plan(items: [late], now: now, policy: policy, calendar: calendar)
        XCTAssertEqual(latePlan.compactMap(\.fireDate).sorted(), [date(6, 7)])

        // 9:30 PM isn't quiet: heads-up at 9:20, nog at 9:30.
        let soon = Item(title: "soon", reminder: Reminder(start: date(5, 21, 30), repeatMinutes: nil))
        let soonPlan = NogPlanner.plan(items: [soon], now: now, policy: policy, calendar: calendar)
        XCTAssertEqual(soonPlan.compactMap(\.fireDate).sorted(), [date(5, 21, 20), date(5, 21, 30)])
    }
}

final class ProfileTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnhingedToken() throws {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)
        let r = try XCTUnwrap(CaptureParser.parse("file taxes !unhinged", defaults: defaults, now: now).reminder)
        XCTAssertEqual(r.start, now.addingTimeInterval(120))
        XCTAssertEqual(r.repeatMinutes, 7)
        XCTAssertEqual(r.escalateAfter, 3)
        XCTAssertEqual(NogProfile.matching(r), .unhinged)
    }

    func testUnhingedRingsAfterThreeIgnoredNogsEvenWhenGlobalEscalationIsOff() {
        let reminder = NogProfile.unhinged.apply(to: Reminder(start: now.addingTimeInterval(-60)))
        let item = Item(title: "taxes", reminder: reminder)
        let alarms = AlarmScheduler.alarmDates(for: item, policy: .standard, now: now, limit: 1)
        XCTAssertEqual(alarms, [now.addingTimeInterval(-60 + 3 * 7 * 60)])
    }

    func testWhisperNeverEscalatesEvenWhenGlobalEscalationIsOn() {
        var policy = NogPolicy.standard
        policy.escalateAfter = 2
        let reminder = NogProfile.whisper.apply(to: Reminder(start: now.addingTimeInterval(-60)))
        let item = Item(title: "someday-ish", reminder: reminder)
        XCTAssertTrue(AlarmScheduler.alarmDates(for: item, policy: policy, now: now).isEmpty)
    }

    func testApplyingAProfileKeepsTheStartAndMatchesBack() {
        let original = Reminder(start: now, repeatMinutes: 30, curve: .steady, alarm: true)
        XCTAssertNil(NogProfile.matching(original))
        let easing = NogProfile.easing.apply(to: original)
        XCTAssertEqual(easing.start, now)
        XCTAssertTrue(easing.alarm, "The alarm switch survives picking a profile")
        XCTAssertEqual(NogProfile.matching(easing), .easing)
    }

    func testProfileSurvivesTheFile() throws {
        var item = Item(title: "x", reminder: NogProfile.unhinged.reminder(from: now))
        item.created = now
        item.updated = now
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item)), item)
    }

    func testEveryProfileMatchesBackToItself() {
        for profile in NogProfile.allCases {
            XCTAssertEqual(NogProfile.matching(profile.reminder(from: now)), profile, profile.label)
        }
    }

    func testEveryProfileHasItsOwnToken() {
        for profile in NogProfile.allCases {
            XCTAssertEqual(NogProfile.token("!" + profile.rawValue), profile)
            XCTAssertEqual(NogProfile.token("!" + profile.rawValue.prefix(3)), profile, "3-letter token for \(profile.label)")
        }
        XCTAssertEqual(NogProfile.token("!tea"), .teatime)
    }

    func testBuildingGapsShrinkToFourMinutes() {
        let r = NogProfile.building.apply(to: Reminder(start: now))
        let gaps = (0..<6).compactMap { r.gap(after: $0) }.map { Int($0 / 60) }
        XCTAssertEqual(gaps, [30, 15, 8, 4, 4, 4])
        XCTAssertEqual(r.settledPhase?.gap, 4 * 60)
        XCTAssertEqual(r.fireDates(after: now, limit: 4),
                       [30, 45, 53, 57].map { now.addingTimeInterval(TimeInterval($0 * 60)) })
    }

    func testBuildingWarnsFifteenFiveAndOneMinuteBeforeItStarts() {
        let start = now.addingTimeInterval(3600)
        let item = Item(title: "leave for bus", reminder: NogProfile.building.apply(to: Reminder(start: start)))
        let plan = NogPlanner.plan(items: [item], now: now)
        let headsUps = plan.filter(\.isHeadsUp).compactMap(\.fireDate).sorted()
        XCTAssertEqual(headsUps, [15, 5, 1].map { start.addingTimeInterval(TimeInterval(-$0 * 60)) })
    }

    func testHushIsSilentNeverRingsAndSurvivesTheFile() throws {
        var policy = NogPolicy.standard
        policy.escalateAfter = 1
        var item = Item(title: "drink water", reminder: NogProfile.hush.apply(to: Reminder(start: now.addingTimeInterval(-60))))
        XCTAssertTrue(try XCTUnwrap(item.reminder).silent)
        XCTAssertTrue(AlarmScheduler.alarmDates(for: item, policy: policy, now: now).isEmpty)
        XCTAssertTrue(NogPlanner.plan(items: [item], now: now).allSatisfy(\.silent))
        item.created = now
        item.updated = now
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item)), item)
        // Picking another profile turns the sound back on.
        XCTAssertFalse(NogProfile.steady.apply(to: try XCTUnwrap(item.reminder)).silent)
    }

    func testRingsThroughSilentMarkFollowsTheAlarmSetting() {
        // "Ring as an alarm after: Never" (the default): only Unhinged can ring.
        XCTAssertEqual(NogProfile.allCases.filter { $0.breaksSilent(globalEscalateAfter: 0) }, [.unhinged])
        // With it on, the profiles that follow the setting can too; the quiet four never do.
        XCTAssertEqual(NogProfile.allCases.filter { $0.breaksSilent(globalEscalateAfter: 3) },
                       [.easing, .steady, .building, .unhinged])
        XCTAssertEqual(NogProfile.unhinged.spokenLabel(globalEscalateAfter: 0), "Unhinged, Rings through Silent")
        XCTAssertEqual(NogProfile.hush.spokenLabel(globalEscalateAfter: 3), "Hush")
    }

    func testTeatimeStartsAtFourAndComesEveryOtherDay() throws {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)
        let r = try XCTUnwrap(CaptureParser.parse("call grandma !tea", defaults: defaults, now: now).reminder)
        let start = r.start
        XCTAssertEqual(Calendar.current.component(.hour, from: start), 16)
        XCTAssertEqual(Calendar.current.component(.minute, from: start), 0)
        XCTAssertGreaterThan(start, now)
        XCTAssertLessThanOrEqual(start, now.addingTimeInterval(86_400))
        XCTAssertEqual(r.repeatMinutes, 2880)
        XCTAssertEqual(r.escalateAfter, 0)
        XCTAssertEqual(NogProfile.matching(r), .teatime)
    }

    func testDailyNogsOnceADayFromTheTimeYouType() throws {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)
        let r = try XCTUnwrap(CaptureParser.parse("meds !daily", defaults: defaults, now: now).reminder)
        XCTAssertEqual(r.start, now.addingTimeInterval(86_400))
        XCTAssertEqual(r.repeatMinutes, 1440)
        XCTAssertEqual(r.escalateAfter, 0)
        XCTAssertEqual(NogProfile.matching(r), .balanced, "!daily picks Balanced, which replaced Daily")
        XCTAssertEqual(r.curve, .balanced)
    }

    func testBalancedGoesFromOnceToTwiceToThreeTimesADay() {
        let r = NogProfile.balanced.apply(to: Reminder(start: now))
        let dates = r.fireDates(after: now.addingTimeInterval(-1), limit: 7 + 14 + 6)
        let gaps = zip(dates, dates.dropFirst()).map { Int($1.timeIntervalSince($0) / 60) }
        XCTAssertEqual(Array(gaps.prefix(7)), Array(repeating: 1440, count: 7))
        XCTAssertEqual(Array(gaps[7..<11]), [360, 1080, 360, 1080])
        XCTAssertEqual(Array(gaps[21..<26]), [240, 240, 960, 240, 240])
        // Every day still starts at the first nog's time of day.
        XCTAssertEqual(dates[21], now.addingTimeInterval(21 * 86_400))
        XCTAssertNil(r.settledPhase, "never one fixed gap, so the planner uses exact times")
        XCTAssertFalse(NogPlanner.plan(items: [Item(title: "x", reminder: r)], now: now.addingTimeInterval(30 * 86_400)).isEmpty)
    }
}

final class MapPageTests: XCTestCase {
    func testTagPageIncludesTaggedItemsAndWhatsFiledUnderThem() {
        var trip = Item(title: "Trip")
        trip.tags = ["Travel"]
        var flights = Item(title: "Book flights")
        flights.parentID = trip.id
        var seat = Item(title: "Pick seat")
        seat.parentID = flights.id
        var passport = Item(title: "Passport")
        passport.tags = ["admin"]
        let all = [trip, flights, seat, passport]

        let travel = Set(MapPage.items(all, page: "travel", showNogged: false).map(\.title))
        XCTAssertEqual(travel, ["Trip", "Book flights", "Pick seat"])
        XCTAssertEqual(MapPage.items(all, page: "", showNogged: false).count, 4)
    }

    func testTagsAreCountedCaseInsensitivelyBusiestFirst() {
        var a = Item(title: "a"); a.tags = ["Travel"]
        var b = Item(title: "b"); b.tags = ["travel", "admin"]
        var c = Item(title: "c", status: .done); c.tags = ["admin"]
        let tags = MapPage.tags([a, b, c], showNogged: false)
        XCTAssertEqual(tags.map(\.tag), ["travel", "admin"])
        XCTAssertEqual(tags.map(\.count), [2, 1])
    }
}

final class IntervalFormatTests: XCTestCase {
    func testAmountsReadNaturallyOnTheirOwn() {
        XCTAssertEqual(IntervalFormat.amount(30), "30 min")
        XCTAssertEqual(IntervalFormat.amount(60), "1 hour")
        XCTAssertEqual(IntervalFormat.amount(120), "2 hours")
        XCTAssertEqual(IntervalFormat.amount(90), "1h 30m")
        XCTAssertEqual(IntervalFormat.amount(1440), "1 day")
        // After "every", the short form still reads "every hour".
        XCTAssertEqual("every \(IntervalFormat.short(60))", "every hour")
    }
}

final class NoRepeatTests: XCTestCase {
    func testNoRepeatTokenAndLabel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r = CaptureParser.parse("call bank !norepeat", defaults: CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8), now: now).reminder
        XCTAssertNotNil(r)
        XCTAssertNil(r?.repeatMinutes)
        XCTAssertEqual(NogSettings.repeatLabel(0), "No repeat")
        // A no-repeat reminder fires exactly once.
        XCTAssertEqual(r?.fireDates(after: now, limit: 5).count, 1)
    }
}

final class TimeTunerTests: XCTestCase {
    func testWrapsAroundMidnight() {
        XCTAssertEqual(TimeTuner.wrap(-5), 1435)
        XCTAssertEqual(TimeTuner.wrap(1440 + 30), 30)
        XCTAssertEqual(TimeTuner.wrap(9 * 60), 540)
    }

    func testSnapsToFiveMinuteSteps() {
        XCTAssertEqual(TimeTuner.snapped(542.4, step: 5), 108)  // 540
        XCTAssertEqual(TimeTuner.snapped(543.0, step: 5), 109)  // 545
    }
}

final class TagFlowTests: XCTestCase {
    func testTagsFlowDownAndParentsComeAlong() {
        let hub = Item(title: "Trip")                       // untagged centre
        var flights = Item(title: "Book flights")
        flights.parentID = hub.id
        flights.tags = ["travel"]                           // only a step is tagged
        var seat = Item(title: "Pick seat")
        seat.parentID = flights.id                          // inherits #travel
        var hotel = Item(title: "Find hotel")
        hotel.parentID = hub.id                             // sibling, not tagged
        let all = [hub, flights, seat, hotel]

        let titles = Set(MapPage.items(all, page: "travel", showNogged: false).map(\.title))
        XCTAssertEqual(titles, ["Trip", "Book flights", "Pick seat"])

        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        XCTAssertEqual(MapPage.effectiveTags(seat, in: byID), ["travel"])
        XCTAssertTrue(MapPage.effectiveTags(hotel, in: byID).isEmpty)
    }

    func testTaggedProjectBringsItsWholeStar() {
        var hub = Item(title: "Trip")
        hub.tags = ["Travel"]
        var a = Item(title: "A"); a.parentID = hub.id
        var b = Item(title: "B"); b.parentID = a.id
        let tags = MapPage.tags([hub, a, b], showNogged: false)
        XCTAssertEqual(tags.first?.tag, "travel")
        XCTAssertEqual(tags.first?.count, 3)
    }
}

final class ArrangeTests: XCTestCase {
    func makeItems() -> [Item] {
        var items: [Item] = []
        var trip = Item(title: "Trip"); trip.tags = ["travel"]
        items.append(trip)
        for i in 0..<6 {
            var step = Item(title: "Step \(i)"); step.parentID = trip.id
            items.append(step)
            if i == 0 {
                for j in 0..<3 { var sub = Item(title: "Sub \(j)"); sub.parentID = step.id; items.append(sub) }
            }
        }
        var admin = Item(title: "Passport"); admin.tags = ["admin"]
        items.append(admin)
        for i in 0..<5 { items.append(Item(title: "Loose \(i)")) }
        return items
    }

    func testNoTwoChipsOverlap() {
        let items = makeItems()
        let p = MapLayout.arrange(items)
        XCTAssertEqual(p.count, items.count)
        // Not just no overlap: keep a gap between chips.
        let w = MapLayout.cell.width + 12, h = MapLayout.cell.height + 10
        let pts = Array(p.values)
        for i in pts.indices {
            for j in pts.indices where j > i {
                let overlaps = abs(pts[i].x - pts[j].x) < w - 0.5 && abs(pts[i].y - pts[j].y) < h - 0.5
                XCTAssertFalse(overlaps, "chips \(i) and \(j) overlap")
            }
        }
    }

    func testSubItemsStayNearTheirProject() {
        let items = makeItems()
        let p = MapLayout.arrange(items)
        let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0.id) })
        let trip = p[byTitle["Trip"]!]!
        for i in 0..<6 {
            let step = p[byTitle["Step \(i)"]!]!
            XCTAssertLessThan(hypot(step.x - trip.x, step.y - trip.y), 600)
        }
    }

    func testDeterministic() {
        let items = makeItems()
        XCTAssertEqual(MapLayout.arrange(items), MapLayout.arrange(items))
    }
}

@MainActor
final class NogSheetTests: XCTestCase {
    func testMovingKeepsTimeOfDay() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 4, hour: 10, minute: 0))!
        let start = calendar.date(from: DateComponents(year: 2030, month: 3, day: 4, hour: 15, minute: 40))!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let moved = NogSheet.moving(start, toDay: tomorrow, now: now)
        XCTAssertEqual(calendar.component(.day, from: moved), 5)
        XCTAssertEqual(calendar.component(.hour, from: moved), 15)
        XCTAssertEqual(calendar.component(.minute, from: moved), 40)
    }

    func testMovingIntoThePastSnapsToNextMark() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 4, hour: 16, minute: 2))!
        let start = calendar.date(from: DateComponents(year: 2030, month: 3, day: 5, hour: 9, minute: 0))!
        let moved = NogSheet.moving(start, toDay: now, now: now)
        XCTAssertGreaterThan(moved, now)
        XCTAssertEqual(calendar.component(.minute, from: moved), 5)
    }

    func testPreviewListsUpcomingNogs() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var item = Item(title: "Call the plumber")
        let reminder = Reminder(start: now.addingTimeInterval(600), repeatMinutes: 8)
        item.reminder = reminder
        let text = NogSheet.preview(item: item, reminder: reminder, now: now, policy: .standard)
        XCTAssertTrue(text.hasPrefix("First nog"))
        XCTAssertTrue(text.hasSuffix("until it's done."))
    }

    func testPreviewWhenPaused() {
        var item = Item(title: "Someday thing")
        item.status = .someday
        let reminder = Reminder(start: .now, repeatMinutes: 8)
        XCTAssertTrue(NogSheet.preview(item: item, reminder: reminder).hasPrefix("Paused"))
    }
}

final class DeliveryDateTests: XCTestCase {
    func testQuietHoursMoveNogsToWhenTheyEnd() {
        let calendar = Calendar.current
        let evening = calendar.date(from: DateComponents(year: 2030, month: 3, day: 5, hour: 21, minute: 50))!
        var policy = NogPolicy.standard
        policy.quiet = QuietHours(enabled: true, start: 22 * 60, end: 7 * 60)
        let reminder = Reminder(start: evening.addingTimeInterval(4 * 60), repeatMinutes: 8)
        let dates = policy.deliveryDates(for: reminder, after: evening, limit: 3)
        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(calendar.component(.hour, from: dates[0]), 21)   // 21:54, before quiet
        XCTAssertEqual(calendar.component(.hour, from: dates[1]), 7)    // the rest wait for 7:00
        XCTAssertEqual(calendar.component(.minute, from: dates[1]), 0)
        XCTAssertGreaterThan(dates[2], dates[1])
    }

    func testNoQuietHoursMatchesFireDates() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let reminder = Reminder(start: now.addingTimeInterval(60), repeatMinutes: 8)
        XCTAssertEqual(NogPolicy.standard.deliveryDates(for: reminder, after: now, limit: 3),
                       reminder.fireDates(after: now, limit: 3))
    }
}

@MainActor
final class RouterTests: XCTestCase {
    func testGoUpPopsWhenYouCameFromTheParent() {
        let router = Router()
        router.tab = .nogs
        let parent = UUID(), child = UUID()
        router.path = [parent, child]
        router.goUp(to: parent)
        XCTAssertEqual(router.path, [parent])
    }

    func testGoUpOpensTheParentOtherwise() {
        let router = Router()
        router.tab = .nogs
        let parent = UUID(), child = UUID()
        router.path = [child]
        router.goUp(to: parent)
        XCTAssertEqual(router.path, [child, parent])
    }
}

final class TagSuggesterTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    func item(_ tags: [String], daysAgo: Double) -> Item {
        var i = Item(title: "x")
        i.tags = tags
        i.created = now.addingTimeInterval(-daysAgo * 86_400)
        i.updated = i.created
        return i
    }

    func testRecentsWhenNothingTyped() {
        let stats = TagSuggester.stats([item(["home"], daysAgo: 10), item(["work"], daysAgo: 1), item(["Home"], daysAgo: 20)])
        XCTAssertEqual(TagSuggester.suggest("", from: stats, now: now), ["work", "home"])
    }

    func testPrefixMatchesComeFirstAndExclusionsAreLeftOut() {
        let stats = TagSuggester.stats([item(["homework"], daysAgo: 1), item(["athome"], daysAgo: 0),
                                        item(["home"], daysAgo: 2), item(["calls"], daysAgo: 0)])
        let s = TagSuggester.suggest("hom", from: stats, excluding: ["HOME"], now: now)
        XCTAssertEqual(s, ["homework", "athome"])
    }

    func testFrequentBeatsOnceAtTheSameAge() {
        let stats = TagSuggester.stats([item(["travel"], daysAgo: 3), item(["travel"], daysAgo: 3), item(["trivia"], daysAgo: 3)])
        XCTAssertEqual(TagSuggester.suggest("tr", from: stats, now: now).first, "travel")
    }

    func testTypingAndCompletingATagInText() {
        XCTAssertEqual(TagSuggester.typingTag(in: "call mum #ho"), "ho")
        XCTAssertEqual(TagSuggester.typingTag(in: "call mum #"), "")
        XCTAssertNil(TagSuggester.typingTag(in: "call mum #home "))
        XCTAssertNil(TagSuggester.typingTag(in: "call mum"))
        XCTAssertEqual(TagSuggester.completing("call mum #ho", with: "home"), "call mum #home ")
        XCTAssertEqual(TagSuggester.writtenTags(in: "#calls mum #ho"), ["calls"])
    }
}

final class SnoozeSettingsTests: XCTestCase {
    func testPerItemSnoozeSurvivesTheFile() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var item = Item(title: "call plumber")
        item.created = now
        item.updated = now
        item.reminder = Reminder(start: now, repeatMinutes: 8, snoozeMinutes: 30, morningMinutes: 8 * 60 + 30)
        XCTAssertTrue(ItemFile.encode(item).contains("snooze_morning: 08:30"))
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item)), item)
    }

    func testCategoryCarriesTheItemsOwnSnooze() {
        XCTAssertEqual(NogPlanner.category(for: nil), "NOG")
        XCTAssertEqual(NogPlanner.category(for: Reminder(start: .now)), "NOG")
        let r = Reminder(start: .now, snoozeMinutes: 30, morningMinutes: 510)
        let id = NogPlanner.category(for: r)
        XCTAssertEqual(id, "NOG_S30_M510")
        let back = NogPlanner.snoozeSettings(fromCategory: id)
        XCTAssertEqual(back.snooze, 30)
        XCTAssertEqual(back.morning, 510)
        XCTAssertNil(NogPlanner.snoozeSettings(fromCategory: "NOG").snooze)
    }

    func testChangingSnoozeReschedulesTheNog() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var item = Item(title: "x", reminder: Reminder(start: now.addingTimeInterval(600)))
        let before = NogPlanner.plan(items: [item], now: now).map(\.identifier)
        item.reminder?.snoozeMinutes = 15
        let after = NogPlanner.plan(items: [item], now: now)
        XCTAssertNotEqual(before, after.map(\.identifier))
        XCTAssertEqual(after.first?.category, "NOG_S15")
    }
}

final class ItemTagTests: XCTestCase {
    func testAddCleansUpAndSkipsDuplicates() {
        var item = Item(title: "x")
        XCTAssertTrue(item.addTag("  #Big trip, "))
        XCTAssertEqual(item.tags, ["Big-trip"])
        XCTAssertFalse(item.addTag("big-TRIP"))
        XCTAssertFalse(item.addTag(" # "))
        XCTAssertEqual(item.tags, ["Big-trip"])
    }

    func testRemoveIgnoresCapitalisation() {
        var item = Item(title: "x")
        item.tags = ["Home", "calls"]
        XCTAssertTrue(item.removeTag("home"))
        XCTAssertEqual(item.tags, ["calls"])
        XCTAssertFalse(item.removeTag("home"))
    }

    func testRemovedTagSurvivesTheFile() {
        var item = Item(title: "x")
        item.tags = ["home", "calls"]
        item.removeTag("calls")
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item))?.tags, ["home"])
    }
}

@MainActor
final class RhythmFlowTests: XCTestCase {
    func makeStore() -> ItemStore {
        ItemStore(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                  schedulesNotifications: false)
    }

    func testNewSubItemTakesItsParentsRhythm() throws {
        let store = makeStore()
        var parent = try XCTUnwrap(store.capture("Trip"))
        parent.reminder = NogProfile.unhinged.apply(to: try XCTUnwrap(parent.reminder))
        parent.reminder?.snoozeMinutes = 30
        store.update(parent)
        let child = try XCTUnwrap(store.capture("Book flights", parent: parent.id))
        XCTAssertEqual(child.reminder?.repeatMinutes, 7)
        XCTAssertEqual(child.reminder?.snoozeMinutes, 30)
        XCTAssertEqual(child.reminder?.followsParent, true)
    }

    func testTypedRhythmKeepsTheSubItemsOwn() throws {
        let store = makeStore()
        var parent = try XCTUnwrap(store.capture("Trip"))
        parent.reminder = NogProfile.unhinged.apply(to: try XCTUnwrap(parent.reminder))
        store.update(parent)
        let child = try XCTUnwrap(store.capture("Pack !whisper", parent: parent.id))
        XCTAssertEqual(child.reminder?.repeatMinutes, NogProfile.whisper.repeatMinutes)
        XCTAssertEqual(child.reminder?.followsParent, false)
    }

    func testParentChangesFlowToFollowersButNotToCustomisedOnes() throws {
        let store = makeStore()
        let parent = try XCTUnwrap(store.capture("Trip"))
        let follower = try XCTUnwrap(store.capture("Book flights", parent: parent.id))
        var custom = try XCTUnwrap(store.capture("Pack", parent: parent.id))
        custom.reminder?.repeatMinutes = 45
        custom.reminder?.followsParent = false
        store.update(custom)
        let grandchild = try XCTUnwrap(store.capture("Window seat", parent: follower.id))

        var p = try XCTUnwrap(store.items[parent.id])
        p.reminder?.repeatMinutes = 3
        p.reminder?.alarm = true
        store.update(p)

        XCTAssertEqual(store.items[follower.id]?.reminder?.repeatMinutes, 3)
        XCTAssertEqual(store.items[follower.id]?.reminder?.alarm, true)
        XCTAssertEqual(store.items[grandchild.id]?.reminder?.repeatMinutes, 3, "flows all the way down")
        XCTAssertEqual(store.items[custom.id]?.reminder?.repeatMinutes, 45)
        // Starts stay their own.
        XCTAssertEqual(store.items[follower.id]?.reminder?.start, follower.reminder?.start)
    }

    func testPassDownOffStopsTheFlow() throws {
        let store = makeStore()
        var parent = try XCTUnwrap(store.capture("Trip"))
        let child = try XCTUnwrap(store.capture("Book flights", parent: parent.id))
        parent.reminder?.passesDown = false
        parent.reminder?.repeatMinutes = 3
        store.update(parent)
        XCTAssertNotEqual(store.items[child.id]?.reminder?.repeatMinutes, 3)
    }

    func testFollowSwitchesSurviveTheFile() {
        var item = Item(title: "x")
        item.created = Date(timeIntervalSince1970: 1_800_000_000)
        item.updated = item.created
        item.reminder = Reminder(start: item.created, repeatMinutes: 8, followsParent: false, passesDown: false)
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item)), item)
        item.reminder = Reminder(start: item.created, repeatMinutes: 8)
        XCTAssertFalse(ItemFile.encode(item).contains("follows_parent"))
    }

    func testBatchAppliesEveryChange() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.capture("a")), b = try XCTUnwrap(store.capture("b"))
        store.batch {
            store.markDone(a.id)
            store.markDone(b.id)
        }
        XCTAssertEqual(store.items[a.id]?.status, .done)
        XCTAssertEqual(store.items[b.id]?.status, .done)
    }
}

final class CaptureDraftTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)

    func testTextAloneWorksAsBefore() {
        let draft = CaptureDraft(text: "call plumber #home")
        let r = draft.resolved(defaults: defaults, now: now)
        XCTAssertEqual(r.title, "call plumber")
        XCTAssertEqual(r.tags, ["home"])
        XCTAssertEqual(r.reminder?.start, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(NogKind.of(r.reminder), .nog)
        XCTAssertFalse(draft.choseOwnRhythm(defaults: defaults, now: now))
    }

    func testTrayChoicesWinOverTheText() {
        let when = now.addingTimeInterval(3 * 3600)
        var draft = CaptureDraft(text: "paint samples !off #home")
        draft.kind = .alarm
        draft.when = when
        draft.profile = .unhinged
        draft.extraTags = ["Kitchen", "HOME"]
        let r = draft.resolved(defaults: defaults, now: now)
        XCTAssertEqual(r.reminder?.start, when)
        XCTAssertEqual(r.reminder?.alarm, true)
        XCTAssertEqual(r.reminder?.repeatMinutes, NogProfile.unhinged.repeatMinutes)
        XCTAssertEqual(r.tags, ["home", "Kitchen"], "no duplicate #home")
        XCTAssertTrue(draft.choseOwnRhythm(defaults: defaults, now: now))
    }

    func testNoteMeansNoReminder() {
        var draft = CaptureDraft(text: "idea for the garden tomorrow 9am")
        draft.kind = .note
        XCTAssertNil(draft.resolved(defaults: defaults, now: now).reminder)
    }

    func testPromiseSaysWhatWillHappen() {
        XCTAssertTrue(NogKind.promise(for: nil).contains("Never nogs"))
        let alarm = Reminder(start: now.addingTimeInterval(600), repeatMinutes: 8, alarm: true)
        XCTAssertTrue(NogKind.promise(for: alarm).contains("even on Silent"))
        let nog = Reminder(start: now.addingTimeInterval(600))
        XCTAssertTrue(NogKind.promise(for: nog).hasSuffix("Quiet on Silent and in Focus."))
    }
}

final class AgendaTests: XCTestCase {
    func testGroupsOnlyTimedOpenThingsWithinTheWeek() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 5, hour: 10))!
        func item(_ title: String, start: Date?, status: ItemStatus = .open) -> Item {
            var i = Item(title: title)
            i.status = status
            i.reminder = start.map { Reminder(start: $0, repeatMinutes: 8) }
            return i
        }
        let items = [
            item("nogging", start: now.addingTimeInterval(-600)),
            item("later", start: now.addingTimeInterval(3 * 3600)),
            item("tomorrow", start: now.addingTimeInterval(24 * 3600)),
            item("friday", start: now.addingTimeInterval(3 * 24 * 3600)),
            item("next month", start: now.addingTimeInterval(30 * 24 * 3600)),
            item("loose", start: nil),
            item("dream", start: now.addingTimeInterval(3600), status: .someday),
            item("done", start: now.addingTimeInterval(3600), status: .done),
        ]
        let groups = Agenda.groups(items, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Now", "Later today", "Tomorrow", "This week"])
        XCTAssertEqual(groups.flatMap(\.entries).map(\.item.title), ["nogging", "later", "tomorrow", "friday"])
        XCTAssertTrue(groups[0].entries[0].isNogging)
        XCTAssertGreaterThan(groups[0].entries[0].when, now, "a nogging item shows its next nog")
    }
}

final class SilenceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    func nogging() -> Item {
        Item(title: "call plumber", reminder: Reminder(start: now.addingTimeInterval(-600), repeatMinutes: 8))
    }

    func testSilencedForAWhileHoldsNogsUntilItEnds() {
        var policy = NogPolicy.standard
        let end = now.addingTimeInterval(2 * 3600)
        policy.silencedUntil = end
        let plan = NogPlanner.plan(items: [nogging()], now: now, policy: policy)
        XCTAssertFalse(plan.isEmpty)
        let dates = plan.compactMap(\.fireDate)
        XCTAssertEqual(dates.min(), end, "the first nog comes as silence ends")
        XCTAssertTrue(dates.allSatisfy { $0 >= end })
    }

    func testSilencedUntilTurnedBackOnPlansNothing() {
        var policy = NogPolicy.standard
        policy.silencedUntil = .distantFuture
        XCTAssertTrue(NogPlanner.plan(items: [nogging()], now: now, policy: policy).isEmpty)
        XCTAssertTrue(policy.deliveryDates(for: nogging().reminder!, after: now, limit: 3).isEmpty)
    }

    func testSilenceThatEndedChangesNothing() {
        var policy = NogPolicy.standard
        policy.silencedUntil = now.addingTimeInterval(-60)
        XCTAssertEqual(NogPlanner.plan(items: [nogging()], now: now, policy: policy),
                       NogPlanner.plan(items: [nogging()], now: now, policy: .standard))
    }

    func testAlarmsDontRingWhileSilenced() {
        var item = nogging()
        item.reminder?.alarm = true
        var policy = NogPolicy.standard
        let end = now.addingTimeInterval(3600)
        policy.silencedUntil = end
        let alarms = AlarmScheduler.alarmDates(for: item, policy: policy, now: now)
        XCTAssertFalse(alarms.isEmpty)
        XCTAssertTrue(alarms.allSatisfy { $0 >= end })
    }
}

final class NogBriefingTests: XCTestCase {
    let calendar = Calendar.current
    lazy var now = calendar.date(from: DateComponents(year: 2030, month: 3, day: 5, hour: 10))!

    func item(_ title: String, start: Date?, status: ItemStatus = .open) -> Item {
        var i = Item(title: title)
        i.status = status
        i.reminder = start.map { Reminder(start: $0, repeatMinutes: 8) }
        return i
    }

    func testNoggingNow() {
        let items = [item("Call plumber", start: now.addingTimeInterval(-600)),
                     item("Reply to Ana", start: now.addingTimeInterval(-60)),
                     item("Later thing", start: now.addingTimeInterval(3 * 3600))]
        XCTAssertEqual(NogBriefing.text(for: .now, items: items, now: now, calendar: calendar),
                       "2 things are nogging: Call plumber and Reply to Ana.")
        XCTAssertEqual(NogBriefing.text(for: .now, items: [], now: now), "Nothing's nogging you right now.")
    }

    func testTodayMentionsTimes() {
        let items = [item("Pay bill", start: now.addingTimeInterval(2 * 3600))]
        let text = NogBriefing.text(for: .today, items: items, now: now, calendar: calendar)
        XCTAssertTrue(text.hasPrefix("Later today: Pay bill at "))
    }

    func testLooseAndLongListsAreShortened() {
        let items = (1...7).map { item("Idea \($0)", start: nil) }
        let text = NogBriefing.text(for: .loose, items: items, now: now, limit: 3)
        XCTAssertTrue(text.hasPrefix("7 loose nogs: "))
        XCTAssertTrue(text.hasSuffix("and 4 more."))
    }

    func testDoingSaysTimeLeft() {
        var doing = Item(title: "Write budget")
        doing.status = .doing
        doing.doingSince = now.addingTimeInterval(-5 * 60)
        doing.timeboxMinutes = 25
        XCTAssertEqual(NogBriefing.text(for: .doing, items: [doing], now: now), "You're on Write budget, 20 minutes left.")
        doing.timeboxMinutes = 2
        XCTAssertEqual(NogBriefing.text(for: .doing, items: [doing], now: now), "You're on Write budget, 5 minutes in and going.")
    }
}

final class ProfileTokenTests: XCTestCase {
    func testFullAndShortTokens() {
        XCTAssertEqual(NogProfile.token("!unhinged"), .unhinged)
        XCTAssertEqual(NogProfile.token("!unh"), .unhinged)
        XCTAssertEqual(NogProfile.token("!UNHI"), .unhinged)
        XCTAssertEqual(NogProfile.token("!whi"), .whisper)
        XCTAssertEqual(NogProfile.token("!eas"), .easing)
        XCTAssertEqual(NogProfile.token("!gentle"), .whisper)
        XCTAssertEqual(NogProfile.unhinged.label, "Unhinged")
    }

    func testOldNamesAndTooShortAreIgnored() {
        XCTAssertNil(NogProfile.token("!relentless"))
        XCTAssertNil(NogProfile.token("!hound"))
        XCTAssertNil(NogProfile.token("!un"))
        XCTAssertNil(NogProfile.token("!unhingedx"))
        XCTAssertNil(NogProfile.token("unhinged"))
        XCTAssertNil(NogProfile.token("!5m"))
    }

    func testCaptureUsesShortToken() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = CaptureDefaults(firstDelayMinutes: 60, repeatMinutes: 60)
        let result = CaptureParser.parse("call back !unh", defaults: defaults, now: now)
        XCTAssertEqual(result.title, "call back")
        XCTAssertEqual(result.reminder?.repeatMinutes, NogProfile.unhinged.repeatMinutes)
        XCTAssertEqual(result.reminder?.escalateAfter, NogProfile.unhinged.escalateAfter)
    }

    func testCompletionSuggestsForLastWord() {
        XCTAssertEqual(CaptureCompletion.suggestions(for: "call back !un"), ["!unhinged"])
        XCTAssertEqual(CaptureCompletion.suggestions(for: "call back !"), CaptureCompletion.tokens)
        XCTAssertTrue(CaptureCompletion.suggestions(for: "call back !unhinged").isEmpty)
        XCTAssertTrue(CaptureCompletion.suggestions(for: "call back !un ").isEmpty)
        XCTAssertTrue(CaptureCompletion.suggestions(for: "call back").isEmpty)
        XCTAssertEqual(CaptureCompletion.complete("call back !un", with: "!unhinged"), "call back !unhinged ")
        XCTAssertEqual(CaptureCompletion.complete("!w", with: "!whisper"), "!whisper ")
    }
}

final class NotificationButtonTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func reminder(_ profile: NogProfile, startsIn minutes: Double = 60) -> Reminder {
        profile.apply(to: Reminder(start: now.addingTimeInterval(minutes * 60)))
    }

    func testCategoryCarriesTheProfilesButtons() {
        XCTAssertEqual(NogPlanner.category(for: reminder(.unhinged)), "NOG_G")
        XCTAssertEqual(NogPlanner.category(for: reminder(.balanced)), "NOG_K")
        XCTAssertEqual(NogPlanner.category(for: reminder(.teatime)), "NOG_K")
        XCTAssertEqual(NogPlanner.category(for: reminder(.hush)), "NOG")
        XCTAssertEqual(NogPlanner.category(for: reminder(.whisper)), "NOG")

        var custom = reminder(.steady)
        custom.snoozeMinutes = 30
        let id = NogPlanner.category(for: custom)
        XCTAssertEqual(id, "NOG_S30_G")
        XCTAssertEqual(NogPlanner.snoozeSettings(fromCategory: id).snooze, 30)
        XCTAssertTrue(NogPlanner.profileButtons(fromCategory: id).gentler)
        XCTAssertFalse(NogPlanner.profileButtons(fromCategory: id).skipToday)
        XCTAssertTrue(NogPlanner.profileButtons(fromCategory: "NOG_K").skipToday)
    }

    func testGentlerStepsDownTheLoudProfilesOnly() {
        XCTAssertEqual(NogProfile.unhinged.gentler, .building)
        XCTAssertEqual(NogProfile.building.gentler, .steady)
        XCTAssertEqual(NogProfile.steady.gentler, .easing)
        XCTAssertEqual(NogProfile.easing.gentler, .whisper)
        for quiet in [NogProfile.hush, .teatime, .whisper, .balanced] { XCTAssertNil(quiet.gentler) }
    }

    func testBannerLineIsInTheProfilesVoice() {
        XCTAssertEqual(NogPlanner.bannerLine(for: reminder(.building)), "Getting louder.")
        XCTAssertEqual(NogPlanner.bannerLine(for: reminder(.teatime)), "Tea time.")
        XCTAssertEqual(NogPlanner.bannerLine(for: Reminder(start: now, repeatMinutes: 10)),
                       "Nogging every 10 min until done")
        XCTAssertEqual(NogPlanner.bannerLine(for: Reminder(start: now)), "Reminder")
        let item = Item(title: "x", reminder: reminder(.building))
        let nogs = NogPlanner.plan(items: [item], now: now).filter { !$0.isHeadsUp }
        XCTAssertEqual(nogs.first?.body, "Getting louder.")
    }

    func testHeadsUpsGetTheirOwnButtons() {
        let item = Item(title: "x", reminder: reminder(.building))
        let plan = NogPlanner.plan(items: [item], now: now)
        let headsUps = plan.filter(\.isHeadsUp)
        XCTAssertEqual(headsUps.count, 3)
        XCTAssertTrue(headsUps.allSatisfy { $0.category == NogPlanner.categoryHeadsUp })
        XCTAssertTrue(plan.filter { !$0.isHeadsUp }.allSatisfy { $0.category == "NOG_G" })
    }

    func testNogsCountDownToTheAlarm() {
        let r = reminder(.unhinged, startsIn: 10)
        let item = Item(title: "x", reminder: r)
        let alarm = r.start.addingTimeInterval(3 * 7 * 60)
        let plan = NogPlanner.plan(items: [item], now: now, maxFollowUpsPerItem: 4, alarmDates: [item.id: [alarm]])
            .filter { !$0.isHeadsUp }
            .sorted { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }
        XCTAssertEqual(plan.prefix(4).map(\.body),
                       ["Alarm after 2 more.", "Alarm after 1 more.", "Alarm next.", "Not letting this go."])
        XCTAssertFalse(plan.contains { $0.fireDate == alarm })
        // The countdown stays put as time passes, so pending nogs aren't needlessly replaced.
        let later = NogPlanner.plan(items: [item], now: now.addingTimeInterval(60), maxFollowUpsPerItem: 4,
                                    alarmDates: [item.id: [alarm]]).filter { !$0.isHeadsUp }
        XCTAssertEqual(Set(plan.map(\.identifier)), Set(later.map(\.identifier)))
    }

    func testLaterReplyReadsTimesAndProfiles() {
        XCTAssertEqual(LaterReply.parse("20", now: now).start, now.addingTimeInterval(20 * 60))
        XCTAssertEqual(LaterReply.parse("20m", now: now).start, now.addingTimeInterval(20 * 60))
        XCTAssertEqual(LaterReply.parse("in 2 hours", now: now).start, now.addingTimeInterval(2 * 3600))
        let hush = LaterReply.parse("!hush", now: now)
        XCTAssertEqual(hush.profile, .hush)
        XCTAssertNil(hush.start)
        let both = LaterReply.parse("1h !tea", now: now)
        XCTAssertEqual(both.profile, .teatime)
        XCTAssertEqual(both.start, now.addingTimeInterval(3600))
        XCTAssertEqual(LaterReply.parse("whatever", now: now), LaterReply())
        XCTAssertNotNil(LaterReply.parse("tomorrow", now: now).start)
    }
}

@MainActor
final class NotificationButtonStoreTests: XCTestCase {
    private func store() -> ItemStore {
        ItemStore(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                  schedulesNotifications: false)
    }

    func testGentlerMovesOneProfileQuieterAndStartsOver() throws {
        let store = store()
        let item = Item(title: "x", reminder: NogProfile.unhinged.apply(to: Reminder(start: .now.addingTimeInterval(-3600))))
        store.insert(item)
        store.makeGentler(item.id)
        let r = try XCTUnwrap(store.items[item.id]?.reminder)
        XCTAssertEqual(NogProfile.matching(r), .building)
        XCTAssertGreaterThan(r.start, .now.addingTimeInterval(25 * 60))

        var quiet = Item(title: "y", reminder: NogProfile.whisper.reminder())
        store.insert(quiet)
        quiet = try XCTUnwrap(store.items[quiet.id])
        store.makeGentler(quiet.id)
        XCTAssertEqual(store.items[quiet.id], quiet, "Whisper has nowhere quieter to go")
    }

    func testSkipTodayKeepsTheTimeOfDay() throws {
        let store = store()
        let calendar = Calendar.current
        let item = Item(title: "x", reminder: NogProfile.balanced.apply(to: Reminder(start: .now.addingTimeInterval(60))))
        store.insert(item)
        let start = try XCTUnwrap(store.items[item.id]?.reminder?.start)
        store.skipToday(item.id)
        let next = try XCTUnwrap(store.items[item.id]?.reminder?.start)
        XCTAssertGreaterThanOrEqual(next, calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: .now)!))
        XCTAssertEqual(calendar.component(.minute, from: next), calendar.component(.minute, from: start))
    }

    func testLaterWithAProfileSwitchesIt() throws {
        let store = store()
        let item = Item(title: "x", reminder: NogProfile.unhinged.reminder())
        store.insert(item)
        store.nogLater(item.id, reply: "30m !hush")
        let r = try XCTUnwrap(store.items[item.id]?.reminder)
        XCTAssertEqual(NogProfile.matching(r), .hush)
        XCTAssertEqual(r.start.timeIntervalSinceNow, 30 * 60, accuracy: 5)
    }

    func testLaterThatMakesNoSenseStillSnoozes() throws {
        let store = store()
        let item = Item(title: "x", reminder: NogProfile.steady.reminder())
        store.insert(item)
        store.nogLater(item.id, reply: "purple")
        let start = try XCTUnwrap(store.items[item.id]?.reminder?.start)
        XCTAssertEqual(start.timeIntervalSinceNow, TimeInterval(NogSettings.snoozeMinutes * 60), accuracy: 5)
    }
}

final class BreakdownStepTests: XCTestCase {
    func testCleanedStripsNumberingAndFullStops() {
        XCTAssertEqual(ItemAssistant.cleaned("1. Find a service shop."), "Find a service shop")
        XCTAssertEqual(ItemAssistant.cleaned("2) Call for an appointment"), "Call for an appointment")
        XCTAssertEqual(ItemAssistant.cleaned("3 - Buy 6 litres of 0W-20 oil"), "Buy 6 litres of 0W-20 oil")
        XCTAssertEqual(ItemAssistant.cleaned("• Buy an oil filter "), "Buy an oil filter")
    }

    func testCleanedKeepsLeadingNumbersThatArePartOfTheStep() {
        XCTAssertEqual(ItemAssistant.cleaned("6 litres of 0W-20"), "6 litres of 0W-20")
        XCTAssertEqual(ItemAssistant.cleaned("2-stroke oil for the mower"), "2-stroke oil for the mower")
    }

    func testInstructionsCarryTheOilChangeExamples() {
        XCTAssertTrue(ItemAssistant.breakdownInstructions.contains("Get the oil changed"))
        XCTAssertTrue(ItemAssistant.breakdownInstructions.contains("Do the oil change"))
    }
}
