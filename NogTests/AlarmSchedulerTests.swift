import AlarmKit
import XCTest
@testable import Nog

@MainActor
private final class FakeAlarmManager: NogAlarmManaging {
    enum Failure: Error { case requested }
    var authorizationState: AlarmManager.AuthorizationState = .authorized
    var snapshots: [NogAlarmSnapshot] = []
    var failingSchedules = false
    var failingReads = false
    var failingCancels = false
    var cancelled: [UUID] = []
    var scheduled: [UUID] = []
    var authorizationRequests = 0

    func requestAuthorization() async throws -> AlarmManager.AuthorizationState {
        authorizationRequests += 1
        authorizationState = .authorized
        return .authorized
    }
    func alarms() throws -> [NogAlarmSnapshot] {
        if failingReads { throw Failure.requested }
        return snapshots
    }
    func cancel(id: UUID) throws {
        if failingCancels { throw Failure.requested }
        cancelled.append(id)
        snapshots.removeAll { $0.id == id }
    }
    func schedule(id: UUID, configuration: AlarmManager.AlarmConfiguration<NogAlarmMetadata>) async throws {
        if failingSchedules { throw Failure.requested }
        // Yield deliberately: simultaneous sync calls must not schedule twice.
        await Task.yield()
        scheduled.append(id)
        snapshots.append(NogAlarmSnapshot(id: id, state: .scheduled))
    }
}

@MainActor
final class AlarmSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ title: String = "Test alarm") -> Item {
        Item(title: title, reminder: Reminder(start: now.addingTimeInterval(60), repeatMinutes: 8, alarm: true))
    }

    private func defaults() -> UserDefaults {
        let suite = "NogAlarmSchedulerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testFailedScheduleKeepsNotificationFallback() async {
        let manager = FakeAlarmManager()
        manager.failingSchedules = true
        let scheduler = AlarmScheduler(manager: manager, defaults: defaults())
        let result = await scheduler.sync(items: [item()], policy: .standard, now: now)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(scheduler.deferredAlarmCount, AlarmScheduler.alarmsPerItem)
    }

    func testBudgetIncludesUnknownRingingAlarms() async {
        let manager = FakeAlarmManager()
        manager.snapshots = (0..<3).map { _ in NogAlarmSnapshot(id: UUID(), state: .alerting) }
        let scheduler = AlarmScheduler(manager: manager, defaults: defaults())
        let items = (0..<20).map { item("Alarm \($0)") }
        let result = await scheduler.sync(items: items, policy: .standard, now: now)
        XCTAssertEqual(manager.snapshots.count, AlarmScheduler.alarmCap)
        XCTAssertEqual(result.values.flatMap { $0 }.count, AlarmScheduler.alarmCap - 3)
        XCTAssertEqual(scheduler.deferredAlarmCount, items.count * AlarmScheduler.alarmsPerItem - (AlarmScheduler.alarmCap - 3))
    }

    func testFailedCancellationsStillConsumeBudget() async {
        let manager = FakeAlarmManager()
        manager.snapshots = (0..<AlarmScheduler.alarmCap).map { _ in NogAlarmSnapshot(id: UUID(), state: .scheduled) }
        manager.failingCancels = true
        let scheduler = AlarmScheduler(manager: manager, defaults: defaults())
        let result = await scheduler.sync(items: [item()], policy: .standard, now: now)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(manager.scheduled.isEmpty)
    }

    func testReadFailureDoesNotScheduleDuplicates() async {
        let manager = FakeAlarmManager()
        manager.failingReads = true
        let scheduler = AlarmScheduler(manager: manager, defaults: defaults())
        let result = await scheduler.sync(items: [item()], policy: .standard, now: now)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(manager.scheduled.isEmpty)
    }

    func testRelaunchCancelsCompletedActiveRing() async {
        let manager = FakeAlarmManager()
        let storage = defaults()
        var nog = item()
        let scheduler = AlarmScheduler(manager: manager, defaults: storage)
        _ = await scheduler.sync(items: [nog], policy: .standard, now: now)
        let ringingID = manager.snapshots[0].id
        manager.snapshots[0] = NogAlarmSnapshot(id: ringingID, state: .alerting)
        nog.status = .done
        let relaunched = AlarmScheduler(manager: manager, defaults: storage)
        _ = await relaunched.sync(items: [nog], policy: .standard, now: now)
        XCTAssertTrue(manager.cancelled.contains(ringingID))
        XCTAssertTrue(manager.snapshots.isEmpty)
    }

    func testRelaunchCancelsDeletedItems() async {
        let manager = FakeAlarmManager()
        let storage = defaults()
        let scheduler = AlarmScheduler(manager: manager, defaults: storage)
        _ = await scheduler.sync(items: [item()], policy: .standard, now: now)
        let relaunched = AlarmScheduler(manager: manager, defaults: storage)
        _ = await relaunched.sync(items: [], policy: .standard, now: now)
        XCTAssertTrue(manager.snapshots.isEmpty)
    }

    func testSnoozedItemDoesNotKeepAlerting() {
        let nog = item()
        XCTAssertFalse(AlarmScheduler.shouldKeepAlerting(item: nog, policy: .standard, now: now))
        var active = nog
        active.reminder?.start = now.addingTimeInterval(-60)
        XCTAssertTrue(AlarmScheduler.shouldKeepAlerting(item: active, policy: .standard, now: now))
        var quiet = NogPolicy.standard
        quiet.silencedUntil = .distantFuture
        XCTAssertFalse(AlarmScheduler.shouldKeepAlerting(item: active, policy: quiet, now: now))
        active.status = .done
        XCTAssertFalse(AlarmScheduler.shouldKeepAlerting(item: active, policy: .standard, now: now))
    }

    func testOverlappingSyncsLeaveExistingIDsAlone() async {
        let manager = FakeAlarmManager()
        let scheduler = AlarmScheduler(manager: manager, defaults: defaults())
        let nog = item()
        let first = Task { await scheduler.sync(items: [nog], policy: .standard, now: now) }
        let second = Task { await scheduler.sync(items: [nog], policy: .standard, now: now) }
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(manager.scheduled.count, AlarmScheduler.alarmsPerItem)
        XCTAssertEqual(Set(manager.scheduled).count, manager.scheduled.count)
    }

    func testAuthorizationIsRequestedOnlyWhenUndetermined() async {
        let manager = FakeAlarmManager()
        let scheduler = AlarmScheduler(manager: manager, defaults: defaults())
        let authorized = await scheduler.requestAuthorization()
        XCTAssertTrue(authorized)
        manager.authorizationState = .denied
        let denied = await scheduler.requestAuthorization()
        XCTAssertFalse(denied)
        XCTAssertEqual(manager.authorizationRequests, 0)
        manager.authorizationState = .notDetermined
        let granted = await scheduler.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertEqual(manager.authorizationRequests, 1)
    }
}
