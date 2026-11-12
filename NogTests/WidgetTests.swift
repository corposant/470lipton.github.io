import XCTest
@testable import Nog

final class WidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func snapshot(_ items: [Item]) -> WidgetSnapshot {
        WidgetSync.snapshot(items, now: now, policy: .standard, defaultTimebox: 25, showTitles: true, calendar: calendar)
    }

    func testSnapshotLeavesOutNoggedAndCountsSubItems() {
        var project = Item(title: "Kitchen reno")
        var a = Item(title: "Photo of the pipe"); a.parentID = project.id
        var b = Item(title: "Quotes"); b.parentID = project.id; b.status = .done
        var done = Item(title: "Old"); done.status = .done
        project.estimateMinutes = 40

        let snap = snapshot([project, a, b, done])
        XCTAssertEqual(Set(snap.entries.map(\.title)), ["Kitchen reno", "Photo of the pipe"])
        let reno = snap.entries.first { $0.id == project.id }!
        XCTAssertEqual(reno.subTotal, 2)
        XCTAssertEqual(reno.subDone, 1)
        XCTAssertEqual(reno.subItems.map(\.title), ["Photo of the pipe", "Quotes"])
        XCTAssertEqual(reno.suggestedMinutes, 40)
        XCTAssertEqual(snap.entries.first { $0.id == a.id }?.parentTitle, "Kitchen reno")
    }

    func testCarriesTheThemeForTheWidgets() throws {
        let item = Item(title: "Call the plumber")
        XCTAssertNil(snapshot([item]).appearance)
        let dark = WidgetSync.snapshot([item], now: now, policy: .standard, defaultTimebox: 25, showTitles: true,
                                       appearance: .dark, calendar: calendar)
        XCTAssertEqual(dark.appearance, "dark")
        // Snapshots written before the theme was added still decode, following the system.
        var old = try XCTUnwrap(String(data: XCTUnwrap(WidgetStore.encode(dark)), encoding: .utf8))
        old = old.replacingOccurrences(of: #""appearance":"dark","#, with: "")
        XCTAssertNil(try XCTUnwrap(WidgetStore.decode(Data(old.utf8))).appearance)
    }

    func testRoundTripsThroughJSON() throws {
        var item = Item(title: "Call the plumber")
        item.reminder = Reminder(start: now.addingTimeInterval(-600), repeatMinutes: 8, alarm: true)
        let snap = snapshot([item])
        let data = try XCTUnwrap(WidgetStore.encode(snap))
        XCTAssertEqual(WidgetStore.decode(data), snap)
    }

    func testDoingIsTheMostRecentlyStarted() {
        var a = Item(title: "A"); a.status = .doing; a.doingSince = now.addingTimeInterval(-600); a.timeboxMinutes = 25
        var b = Item(title: "B"); b.status = .doing; b.doingSince = now.addingTimeInterval(-60)
        let snap = snapshot([a, b])
        XCTAssertEqual(snap.doing?.title, "B")
        XCTAssertEqual(snap.entries.first { $0.title == "A" }?.timeboxEnd, now.addingTimeInterval(-600 + 25 * 60))
    }
}

final class WidgetPickerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func entry(_ title: String, status: String = "open", start: TimeInterval? = nil,
                       tags: [String] = [], age: TimeInterval = 0) -> WidgetSnapshot.Entry {
        WidgetSnapshot.Entry(id: UUID(), title: title, status: status, tags: tags, parentTitle: nil,
                             start: start.map { now.addingTimeInterval($0) }, nextNog: nil, alarm: false,
                             suggestedMinutes: 15, doingSince: status == "doing" ? now : nil, timeboxMinutes: nil,
                             subItems: [], subDone: 0, subTotal: 0, updated: now.addingTimeInterval(-age))
    }

    private func sections(_ entries: [WidgetSnapshot.Entry], _ lists: [WidgetListKind], tag: String? = nil,
                          pinned: [UUID] = []) -> [WidgetPicker.Section] {
        WidgetPicker.sections(WidgetSnapshot(generated: now, entries: entries, showTitlesOnLockScreen: true),
                              lists: lists, tag: tag, pinned: pinned, at: now, calendar: calendar)
    }

    func testListsInOrderEachNogOnce() {
        let older = entry("Plumber", start: -1800)
        let newer = entry("Ana", start: -60)
        let later = entry("Paint", start: 3600)
        let tomorrow = entry("Dentist", start: 86_400)
        let loose = entry("Garage")
        let dream = entry("Boat", status: "someday")
        let doing = entry("Budget", status: "doing")
        let all = [newer, later, loose, older, tomorrow, dream, doing]

        let result = sections(all, [.nogging, .today, .loose])
        XCTAssertEqual(result.map(\.title), ["Due now", "Today", "No reminder"])
        XCTAssertEqual(result[0].entries.map(\.title), ["Plumber", "Ana"]) // longest nogging first
        XCTAssertEqual(result[1].entries.map(\.title), ["Paint"]) // nogging ones already shown
        XCTAssertEqual(result[2].entries.map(\.title), ["Garage"])

        XCTAssertEqual(sections(all, [.agenda]).first?.entries.map(\.title), ["Plumber", "Ana", "Paint", "Dentist"])
        XCTAssertEqual(sections(all, [.dream]).first?.entries.map(\.title), ["Boat"])
    }

    func testNowIsNoggingThenRestOfToday() {
        var alarm = entry("Meds", start: -60)
        alarm.alarm = true
        let older = entry("Plumber", start: -1800)
        let later = entry("Paint", start: 3600)
        let tomorrow = entry("Dentist", start: 86_400)
        let loose = entry("Garage")
        let dream = entry("Boat", status: "someday")
        let doing = entry("Budget", status: "doing")

        let result = sections([later, loose, older, tomorrow, dream, doing, alarm], [.now])
        XCTAssertEqual(result.map(\.title), ["Now"])
        // Alarms first, then longest nogging, then later today; nothing from tomorrow or loose.
        XCTAssertEqual(result[0].entries.map(\.title), ["Meds", "Plumber", "Paint"])
    }

    func testTagFilterAndPinnedPicks() {
        let a = entry("Paint samples", tags: ["Kitchen"])
        let b = entry("Order tiles", start: -60, tags: ["kitchen"])
        let c = entry("Call mom", start: -60, tags: ["calls"])
        let tagged = sections([a, b, c], [.nogging, .loose], tag: "#kitchen")
        XCTAssertEqual(tagged.flatMap(\.entries).map(\.title), ["Order tiles", "Paint samples"])

        let picked = sections([a, b, c], [.nogging], pinned: [c.id, a.id])
        XCTAssertEqual(picked.map(\.title), ["Your picks"])
        XCTAssertEqual(picked[0].entries.map(\.title), ["Call mom", "Paint samples"])
    }

    func testChangeDates() {
        var doing = entry("Budget", status: "doing")
        doing.timeboxMinutes = 25
        let snap = WidgetSnapshot(generated: now, entries: [entry("Paint", start: 3600), entry("Old", start: -60), doing],
                                  showTitlesOnLockScreen: true)
        XCTAssertEqual(WidgetPicker.changeDates(snap, after: now),
                       [now.addingTimeInterval(25 * 60), now.addingTimeInterval(3600)])
    }

    func testBoxFormat() {
        XCTAssertEqual(BoxFormat.short(15), "15m")
        XCTAssertEqual(BoxFormat.short(60), "1h")
        XCTAssertEqual(BoxFormat.short(90), "1h30")
        XCTAssertNil(BoxFormat.short(nil))
    }
}
