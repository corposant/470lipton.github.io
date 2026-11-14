import XCTest
@testable import Nog

/// Synthetic fixtures only. These tests must execute in Xcode before release.
final class StorageSafetyTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFailedWriteIsRetainedAndRetrySucceeds() async throws {
        let root = try temporaryFolder()
        let parent = root.appending(path: "not-created")
        let file = parent.appending(path: "note.md")
        let storage = FileStorage()
        storage.write("Retain me", to: file)
        await storage.flush()
        let failed = await storage.failedPaths()
        XCTAssertEqual(failed, ["note.md"])
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await storage.retryFailed()
        let remaining = await storage.failedPaths()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Retain me")
    }

    func testNewerMutationSupersedesFailedWrite() async throws {
        let root = try temporaryFolder()
        let parent = root.appending(path: "not-created")
        let file = parent.appending(path: "note.md")
        let storage = FileStorage()
        storage.write("Old", to: file)
        await storage.flush()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        storage.write("New", to: file)
        await storage.flush()
        await storage.retryFailed()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "New")
    }

    func testFailedMigrationRetainsLocalOriginal() throws {
        let local = try temporaryFolder()
        let cloud = try temporaryFolder()
        let item = Item(title: "Newer local notes", body: "Only good copy")
        let name = "\(item.id.uuidString).md"
        let localFile = local.appending(path: name)
        try ItemFile.encode(item).write(to: localFile, atomically: true, encoding: .utf8)
        // A directory in place of the destination file makes the read fail.
        try FileManager.default.createDirectory(at: cloud.appending(path: name), withIntermediateDirectories: true)
        XCTAssertThrowsError(try FileStorage.migrate(from: local, to: cloud))
        XCTAssertEqual(try String(contentsOf: localFile, encoding: .utf8), ItemFile.encode(item))
    }

    func testMigrationCopiesSidecarsAndRetainsLosingVersion() throws {
        let local = try temporaryFolder()
        let cloud = try temporaryFolder()
        var newer = Item(title: "New", body: "New text")
        newer.updated = Date(timeIntervalSince1970: 2_000_000_000)
        var older = newer
        older.title = "Old"
        older.body = "Old text"
        older.updated = newer.updated.addingTimeInterval(-60)
        let name = "\(newer.id.uuidString).md"
        try ItemFile.encode(newer).write(to: local.appending(path: name), atomically: true, encoding: .utf8)
        try ItemFile.encode(older).write(to: cloud.appending(path: name), atomically: true, encoding: .utf8)
        try Data("{\"positions\":{}}".utf8).write(to: local.appending(path: "_nogmap.json"))
        try FileStorage.migrate(from: local, to: cloud)
        XCTAssertEqual(try String(contentsOf: cloud.appending(path: name), encoding: .utf8), ItemFile.encode(newer))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appending(path: "_nogmap.json").path))
        let recovery = try FileManager.default.contentsOfDirectory(at: cloud.appending(path: "_recovery"), includingPropertiesForKeys: nil)
        XCTAssertTrue(try recovery.contains { try Data(contentsOf: $0) == Data(ItemFile.encode(older).utf8) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appending(path: name).path))
    }
}

@MainActor
final class StoreReviewRegressionTests: XCTestCase {
    func testReorderMergesIntoAlreadyLoadedPeer() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ItemStore(folder: folder, schedulesNotifications: false)
        let parent = first.createIdea(title: "Parent")
        let a = Item(title: "A", created: Date(timeIntervalSince1970: 100), parentID: parent.id)
        let b = Item(title: "B", created: Date(timeIntervalSince1970: 200), parentID: parent.id)
        first.insert(a)
        first.insert(b)
        let initialSaved = await first.flush()
        XCTAssertTrue(initialSaved)
        let peer = ItemStore(folder: folder, schedulesNotifications: false)
        first.moveChildren(of: parent.id, from: [1], to: 0)
        let reorderedSaved = await first.flush()
        XCTAssertTrue(reorderedSaved)
        await peer.reloadFromDisk()
        XCTAssertEqual(peer.children(of: parent.id).map(\.id), [b.id, a.id])
    }

    func testStoreReportsFailedWriteAndRetriesWithoutLosingEdit() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ItemStore(folder: folder, schedulesNotifications: false)
        // Constructor creates the folder; replace it with a file to force failure.
        try FileManager.default.removeItem(at: folder)
        try Data("blocked".utf8).write(to: folder)
        let item = store.createIdea(title: "Keep this edit")
        let saved = await store.flush()
        XCTAssertFalse(saved)
        XCTAssertNotNil(store.persistenceIssue)
        XCTAssertEqual(store.items[item.id]?.title, "Keep this edit")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await store.retrySaving()
        let retried = await store.flush()
        XCTAssertTrue(retried)
        let peer = ItemStore(folder: folder, schedulesNotifications: false)
        XCTAssertEqual(peer.items[item.id]?.title, "Keep this edit")
    }

    func testDoingPrivacyStateRedactsAndUpdatesTitle() {
        let defaults = UserDefaults.standard
        let key = NogSettings.Key.showTitles
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let item = Item(title: "Private note", status: .doing, doingSince: .now)
        defaults.set(false, forKey: key)
        XCTAssertEqual(DoingActivities.content(for: item).state.displayTitle, "Nog")
        defaults.set(true, forKey: key)
        XCTAssertEqual(DoingActivities.content(for: item).state.displayTitle, "Private note")
    }

    func testMapTagFilenamesDoNotCollide() {
        XCTAssertNotEqual(MapDocument(page: "home-office").fileName,
                          MapDocument(page: "home_office").fileName)
        XCTAssertEqual(MapDocument(page: "HOME").fileName, MapDocument(page: "home").fileName)
        XCTAssertEqual(MapDocument().fileName, "_nogmap.json")
    }

    func testMapPendingSaveParticipatesInStoreFlush() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ItemStore(folder: folder, schedulesNotifications: false)
        let item = store.createIdea(title: "Map item")
        let doc = MapDocument()
        doc.load(from: store)
        doc.move(item.id, to: CGPoint(x: 10, y: 20))
        // Do not wait for MapDocument's debounce.
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let reloaded = MapDocument()
        reloaded.load(from: store)
        XCTAssertEqual(reloaded.positions[item.id], CGPoint(x: 10, y: 20))
    }
}

final class ReminderReviewRegressionTests: XCTestCase {
    func testOldSteadyReminderStillProducesFutureDates() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = Reminder(start: start, repeatMinutes: 1)
        for age in [99_999.5, 100_000.5, 1_000_000.5] {
            let dates = reminder.fireDates(after: start.addingTimeInterval(age * 60), limit: 2)
            XCTAssertEqual(dates.count, 2)
            XCTAssertEqual(dates.first, start.addingTimeInterval((floor(age) + 1) * 60))
        }
    }

    func testIndefiniteSilenceRemovesPlaceRequests() {
        var policy = NogPolicy.standard
        policy.silencedUntil = .distantFuture
        let item = Item(title: "At home", place: PlaceTrigger(name: "Home"))
        let home = SavedPlace(name: "Home", latitude: 0, longitude: 0)
        XCTAssertTrue(NogPlanner.placeNotifications(items: [item], places: [home], limit: 15,
                                                    policy: policy).isEmpty)
        XCTAssertEqual(NogPlanner.placeNotifications(items: [item], places: [home], limit: 15).count, 1)
    }

    func testHiddenPresentationTitleDoesNotContainPrivateText() {
        XCTAssertEqual(PresentationPrivacy.title("Private title", visible: false), "Nog")
        XCTAssertEqual(PresentationPrivacy.title("Private title", visible: true), "Private title")
    }

    func testUnsafeImportedTimingIsRejected() {
        let base = "---\nid: \(UUID().uuidString)\ntitle: Imported\n"
        XCTAssertNil(ItemFile.decode(base + "time_spent: nan\n---\n"))
        XCTAssertNil(ItemFile.decode(base + "timebox_minutes: -10\n---\n"))
        XCTAssertNil(ItemFile.decode(base + "remind_at: 2026-11-14T12:00:00Z\nrepeat_minutes: \(Int.max)\n---\n"))
        XCTAssertNil(Recurrence(encoded: "weeks:\(Int.max)"))
    }

    func testSortKeepsMissingDatesLastWhenReversed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let early = Item(title: "Early", reminder: Reminder(start: now.addingTimeInterval(60)))
        let late = Item(title: "Late", reminder: Reminder(start: now.addingTimeInterval(120)))
        let none = Item(title: "No date")
        let all = [none, early, late]
        XCTAssertEqual(ListSort.next.sorted(all, now: now, stats: ChildStats(all), reversed: true).map(\.id),
                       [late.id, early.id, none.id])
    }
}
