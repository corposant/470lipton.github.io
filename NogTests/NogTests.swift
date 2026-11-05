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
        XCTAssertEqual(r.title, "call mom")
        XCTAssertEqual(r.reminder, Reminder(start: now.addingTimeInterval(15 * 60), repeatMinutes: 8))
    }

    func testOverrides() {
        let r = CaptureParser.parse("pay rent !2h @1d #money", defaults: defaults, now: now)
        XCTAssertEqual(r.title, "pay rent")
        XCTAssertEqual(r.tags, ["money"])
        XCTAssertEqual(r.reminder, Reminder(start: now.addingTimeInterval(86_400), repeatMinutes: 120))
    }

    func testOffAndOnce() {
        XCTAssertNil(CaptureParser.parse("app idea !off", defaults: defaults, now: now).reminder)
        XCTAssertNil(CaptureParser.parse("x !once", defaults: defaults, now: now).reminder?.repeatMinutes)
    }

    func testNonTokensStayInTitle() {
        let r = CaptureParser.parse("meet @home !important wow!", defaults: defaults, now: now)
        XCTAssertEqual(r.title, "meet @home !important wow!")
    }
}

final class NagPlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ title: String, startOffset: TimeInterval, every: Int?, status: ItemStatus = .open) -> Item {
        Item(title: title, status: status,
             reminder: Reminder(start: now.addingTimeInterval(startOffset), repeatMinutes: every))
    }

    func testActiveItemGetsOneRepeatingTrigger() {
        let plan = NagPlanner.plan(items: [item("a", startOffset: -600, every: 8)], now: now)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.trigger, .every(480))
    }

    func testFutureItemGetsStartPlusFollowUps() {
        let plan = NagPlanner.plan(items: [item("a", startOffset: 600, every: 8)], now: now, maxFollowUpsPerItem: 3)
        XCTAssertEqual(plan.map(\.fireDate), [600, 1080, 1560, 2040].map { now.addingTimeInterval($0) })
    }

    func testDoneAndPastOneShotsAreSkipped() {
        let plan = NagPlanner.plan(items: [
            item("done", startOffset: -60, every: 8, status: .done),
            item("past once", startOffset: -60, every: nil),
        ], now: now)
        XCTAssertTrue(plan.isEmpty)
    }

    func testBudgetPrefersEveryItemsFirstNag() {
        let items = (0..<10).map { item("i\($0)", startOffset: Double($0 + 1) * 60, every: 1) }
        let plan = NagPlanner.plan(items: items, now: now, budget: 12)
        XCTAssertEqual(plan.count, 12)
        XCTAssertEqual(Set(plan.map(\.itemID)).count, 10)
    }

    func testIdentifiersAreStable() {
        let a = item("a", startOffset: -600, every: 8)
        XCTAssertEqual(NagPlanner.plan(items: [a], now: now).map(\.identifier),
                       NagPlanner.plan(items: [a], now: now.addingTimeInterval(1000)).map(\.identifier))
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

        let reloaded = ItemStore(folder: folder, schedulesNotifications: false)
        XCTAssertEqual(reloaded.items.count, 2)
        XCTAssertEqual(reloaded.children(of: parent.id).map(\.id), [child.id])
        XCTAssertEqual(reloaded.items[child.id]?.status, .done)
        XCTAssertNotNil(reloaded.items[child.id]?.completed)
    }
}
