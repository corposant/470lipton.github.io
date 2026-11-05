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

        let settledPlan = NogPlanner.plan(items: [easing], now: minutes(5000))
        XCTAssertEqual(settledPlan.map(\.trigger), [.every(86_400)])
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

    func done(_ title: String, tags: [String] = [], parent: UUID? = nil, minutes: Double) -> Item {
        var item = Item(title: title, status: .done, parentID: parent, tags: tags)
        item.timeSpent = minutes * 60
        return item
    }

    func testSuggestionPrefersEstimateThenHistoryThenUrgencyThenDefault() {
        var item = Item(title: "call bank", tags: ["calls"])
        item.estimateMinutes = 20
        let history = [done("a", tags: ["calls"], minutes: 9), done("b", tags: ["Calls"], minutes: 11),
                       done("c", tags: ["calls"], minutes: 30)]
        XCTAssertEqual(TimeboxAdvisor.suggest(for: item, among: history, defaultMinutes: 25, now: now).minutes, 20)

        item.estimateMinutes = nil
        let byTag = TimeboxAdvisor.suggest(for: item, among: history, defaultMinutes: 25, now: now)
        XCTAssertEqual(byTag, TimeboxSuggestion(minutes: 10, reason: "like your other #calls"))

        let lonely = Item(title: "x", reminder: Reminder(start: now.addingTimeInterval(-2 * 86_400), repeatMinutes: 8))
        XCTAssertEqual(TimeboxAdvisor.suggest(for: lonely, among: [], defaultMinutes: 25, now: now).minutes, 10)

        let urgent = Item(title: "y", reminder: Reminder(start: now, repeatMinutes: 8, alarm: true))
        XCTAssertEqual(TimeboxAdvisor.suggest(for: urgent, among: [], defaultMinutes: 25, now: now).minutes, 15)

        XCTAssertEqual(TimeboxAdvisor.suggest(for: Item(title: "z"), among: [], defaultMinutes: 25, now: now).minutes, 25)
        XCTAssertNil(TimeboxAdvisor.suggest(for: Item(title: "z"), among: [], defaultMinutes: 0, now: now).minutes)
    }

    func testDoingNogsWhenTimeIsUpInsteadOfTheUsualReminder() {
        var item = Item(title: "write", status: .doing, reminder: Reminder(start: now.addingTimeInterval(-3600), repeatMinutes: 8))
        item.doingSince = now
        item.timeboxMinutes = 25
        XCTAssertEqual(item.effectiveReminder, Reminder(start: now.addingTimeInterval(1500), repeatMinutes: 5))

        let plan = NogPlanner.plan(items: [item], now: now.addingTimeInterval(60), maxFollowUpsPerItem: 1)
        XCTAssertEqual(plan.first?.fireDate, now.addingTimeInterval(1500))
        XCTAssertEqual(plan.first?.category, NogPlanner.categoryDoing)
    }

    func testStartFinishBanksTimeAndKeepsTheItem() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ItemStore(folder: folder, schedulesNotifications: false)
        let item = try XCTUnwrap(store.capture("write report ~45m"))
        XCTAssertEqual(item.estimateMinutes, 45)
        XCTAssertEqual(store.suggestedTimebox(for: item.id).minutes, 45)

        store.start(item.id)
        XCTAssertEqual(store.items[item.id]?.status, .doing)
        XCTAssertEqual(store.items[item.id]?.timeboxMinutes, 45)
        XCTAssertNotNil(store.items[item.id]?.doingSince)

        store.extend(item.id, minutes: 10)
        XCTAssertEqual(store.items[item.id]?.timeboxMinutes, 55)

        store.markDone(item.id)
        let finished = try XCTUnwrap(store.items[item.id])
        XCTAssertEqual(finished.status, .done)
        XCTAssertNil(finished.doingSince)
        XCTAssertNotNil(finished.completed)
        XCTAssertGreaterThanOrEqual(finished.timeSpent, 0)

        store.flushForTesting()
        let reloaded = ItemStore(folder: folder, schedulesNotifications: false)
        XCTAssertEqual(reloaded.items[item.id]?.estimateMinutes, 45)
        XCTAssertEqual(reloaded.items[item.id]?.status, .done)
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

    func testRelentlessToken() throws {
        let defaults = CaptureDefaults(firstDelayMinutes: 15, repeatMinutes: 8)
        let r = try XCTUnwrap(CaptureParser.parse("file taxes !relentless", defaults: defaults, now: now).reminder)
        XCTAssertEqual(r.start, now.addingTimeInterval(120))
        XCTAssertEqual(r.repeatMinutes, 7)
        XCTAssertEqual(r.escalateAfter, 3)
        XCTAssertEqual(NogProfile.matching(r), .relentless)
    }

    func testRelentlessRingsAfterThreeIgnoredNogsEvenWhenGlobalEscalationIsOff() {
        let reminder = NogProfile.relentless.apply(to: Reminder(start: now.addingTimeInterval(-60)))
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
        XCTAssertEqual(NogProfile.matching(easing), .easing)
    }

    func testProfileSurvivesTheFile() throws {
        var item = Item(title: "x", reminder: NogProfile.relentless.reminder(from: now))
        item.created = now
        item.updated = now
        XCTAssertEqual(ItemFile.decode(ItemFile.encode(item)), item)
    }
}
