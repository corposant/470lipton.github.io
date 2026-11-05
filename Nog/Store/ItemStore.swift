import Foundation
import Observation

/// Holds all items in memory and mirrors each one to `<folder>/<id>.md`,
/// where the folder is iCloud Drive/Nog/Items when iCloud is available.
@MainActor
@Observable
final class ItemStore {
    static let shared = ItemStore(folder: StorageLocation.lastKnownFolder())

    private(set) var items: [UUID: Item] = [:]
    private(set) var folder: URL
    private(set) var isUsingICloud = false

    private let schedulesNotifications: Bool
    private let storage = FileStorage()
    @ObservationIgnored private var syncDebounce: Task<Void, Never>?
    @ObservationIgnored private var reloadDebounce: Task<Void, Never>?
    @ObservationIgnored private var recentlyWritten: [UUID: Date] = [:]
    @ObservationIgnored private var recentlyDeleted: [UUID: Date] = [:]
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var queryObservers: [NSObjectProtocol] = []

    init(folder: URL? = nil, schedulesNotifications: Bool = true) {
        self.folder = folder ?? StorageLocation.localFolder
        self.schedulesNotifications = schedulesNotifications
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistence

    /// Fast, synchronous load of whatever is already on disk.
    func load() {
        let snapshot = FileStorage.readAllNow(in: folder, coordinated: false)
        items = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.updated >= b.updated ? a : b })
    }

    private func fileURL(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).md")
    }

    private func write(_ item: Item) {
        recentlyWritten[item.id] = .now
        storage.write(ItemFile.encode(item), to: fileURL(for: item.id))
    }

    /// Waits for pending disk writes (call before the app may be suspended).
    func flush() async { await storage.flush() }

    func flushForTesting() { storage.flushSync() }

    // MARK: - iCloud

    /// Switches storage to iCloud Drive/Nog/Items if iCloud is available,
    /// moving any on-phone items there, then watches for changes from other devices.
    func connectToICloud() async {
        let local = StorageLocation.localFolder
        guard StorageMode.current == .iCloud else {
            await useLocalStorage()
            return
        }
        guard let cloud = await storage.resolveICloudFolder(migratingFrom: local) else {
            isUsingICloud = false
            UserDefaults.standard.removeObject(forKey: StorageLocation.lastFolderKey)
            if folder.standardizedFileURL != local.standardizedFileURL {
                folder = local
                try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                load()
            }
            return
        }
        UserDefaults.standard.set(cloud.path, forKey: StorageLocation.lastFolderKey)
        isUsingICloud = true
        if folder.standardizedFileURL != cloud.standardizedFileURL {
            folder = cloud
            // Anything captured while we were switching goes to the new folder too.
            let snapshot = await storage.readAll(in: cloud, coordinated: true)
            for item in items.values where !snapshot.presentIDs.contains(item.id) { write(item) }
        }
        await reloadFromDisk()
        startWatching()
    }

    /// Settings → Storage. Switching to on-phone copies every item to the phone
    /// (the iCloud copies stay put); switching back merges, keeping the newest edits.
    func setStorage(_ mode: StorageMode) async {
        UserDefaults.standard.set(mode.rawValue, forKey: StorageMode.key)
        switch mode {
        case .local: await useLocalStorage()
        case .iCloud: await connectToICloud()
        }
        await syncNow()
    }

    private func useLocalStorage() async {
        stopWatching()
        UserDefaults.standard.removeObject(forKey: StorageLocation.lastFolderKey)
        let local = StorageLocation.localFolder
        let wasElsewhere = folder.standardizedFileURL != local.standardizedFileURL
        isUsingICloud = false
        guard wasElsewhere else { return }
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        folder = local
        for item in items.values { write(item) }
        await flush()
    }

    private func stopWatching() {
        query?.stop()
        query = nil
        for observer in queryObservers { NotificationCenter.default.removeObserver(observer) }
        queryObservers = []
    }

    /// Merges what's on disk (possibly changed by another device) into memory.
    func reloadFromDisk() async {
        let snapshot = await storage.readAll(in: folder, coordinated: isUsingICloud)
        let now = Date.now
        func isRecent(_ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) < 60 } ?? false }

        var next = items
        for disk in snapshot.items {
            if let mine = next[disk.id] {
                if disk.updated > mine.updated { next[disk.id] = disk }
            } else if !isRecent(recentlyDeleted[disk.id]) {
                next[disk.id] = disk
            }
        }
        for id in Array(next.keys) where !snapshot.presentIDs.contains(id) && !isRecent(recentlyWritten[id]) {
            next[id] = nil // deleted on another device
        }
        if next != items {
            items = next
            scheduleSync()
        }
    }

    private func startWatching() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleReload() }
            })
        }
        query.start()
        self.query = query
    }

    private func scheduleReload() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.reloadFromDisk()
        }
    }

    // MARK: - Mutations

    /// Quick capture: parses the text, applies the default nog, saves.
    @discardableResult
    func capture(_ text: String, parent: UUID? = nil, now: Date = .now) -> Item? {
        let parsed = CaptureParser.parse(text, defaults: NogSettings.captureDefaults, now: now)
        guard !parsed.title.isEmpty else { return nil }
        var item = Item(title: parsed.title, created: now, updated: now,
                        parentID: parent, tags: parsed.tags, reminder: parsed.reminder)
        item.estimateMinutes = parsed.estimateMinutes
        insert(item)
        return item
    }

    /// Creates a reminder-less item (e.g. from an unresolved [[link]]).
    @discardableResult
    func createIdea(title: String) -> Item {
        let item = Item(title: title)
        insert(item)
        return item
    }

    func insert(_ item: Item) {
        items[item.id] = item
        write(item)
        scheduleSync()
    }

    func update(_ newValue: Item) {
        guard let old = items[newValue.id] else { return insert(newValue) }
        guard old != newValue else { return }
        var item = newValue
        let now = Date.now
        if old.status != .done && item.status == .done {
            item.completed = now
            clearDelivered(item.id)
        } else if item.status != .done {
            item.completed = nil
        }
        // ▶︎ Doing: start a session / bank the time when it ends
        if old.status != .doing && item.status == .doing {
            item.doingSince = now
            clearDelivered(item.id)
        } else if old.status == .doing && item.status != .doing {
            if let since = old.doingSince { item.timeSpent += max(0, now.timeIntervalSince(since)) }
            item.doingSince = nil
            item.timeboxMinutes = nil
        }
        item.updated = now
        items[item.id] = item
        write(item)
        if old.status != item.status || old.doingSince != item.doingSince
            || old.timeboxMinutes != item.timeboxMinutes || old.title != item.title {
            updateLiveActivities()
            // Doing changes should nog (or stop nogging) right away.
            if old.status != item.status || old.timeboxMinutes != item.timeboxMinutes {
                Task { await syncNow() }
                return
            }
        }
        scheduleSync()
    }

    // MARK: - Doing (▶︎)

    /// The timebox ▶︎ would use for this item right now.
    func suggestedTimebox(for id: UUID) -> TimeboxSuggestion {
        guard let item = items[id] else { return TimeboxSuggestion(minutes: nil, reason: "open-ended") }
        return TimeboxAdvisor.suggest(for: item, among: Array(items.values),
                                      defaultMinutes: NogSettings.timeboxMinutes, now: .now)
    }

    /// Starts working on an item. `timebox` nil = open-ended.
    func start(_ id: UUID, timebox: Int?) {
        guard var item = items[id] else { return }
        if item.isDoing { // restart with a new timebox
            item.status = .open
            update(item)
            guard let refreshed = items[id] else { return }
            item = refreshed
        }
        item.status = .doing
        item.timeboxMinutes = timebox
        update(item)
    }

    /// Starts with the suggested timebox.
    func start(_ id: UUID) {
        start(id, timebox: suggestedTimebox(for: id).minutes)
    }

    /// Adds time to the current timebox (or turns an open-ended session into one).
    func extend(_ id: UUID, minutes: Int) {
        guard var item = items[id], item.isDoing, let since = item.doingSince else { return }
        let elapsed = Int(Date.now.timeIntervalSince(since) / 60)
        let currentEnd = item.timeboxMinutes ?? elapsed
        item.timeboxMinutes = max(currentEnd, elapsed) + minutes
        clearDelivered(id)
        update(item)
    }

    /// Stops working without finishing; the item goes back to Open.
    func stopDoing(_ id: UUID) {
        guard var item = items[id], item.isDoing else { return }
        item.status = .open
        update(item)
    }

    private func updateLiveActivities() {
        guard schedulesNotifications else { return }
        DoingActivities.shared.reconcile(Array(items.values))
    }

    func markDone(_ id: UUID) {
        guard var item = items[id] else { return }
        item.status = .done
        update(item)
    }

    func reopen(_ id: UUID) {
        guard var item = items[id] else { return }
        item.status = .open
        update(item)
    }

    /// Pushes the nog start to `date` (creating a default reminder if the item had none).
    func snooze(_ id: UUID, until date: Date) {
        guard var item = items[id] else { return }
        if var r = item.reminder {
            r.start = date
            item.reminder = r
        } else {
            item.reminder = Reminder(start: date, repeatMinutes: NogSettings.repeatMinutes, curve: NogSettings.curve)
        }
        item.status = .open
        clearDelivered(id)
        update(item)
    }

    func delete(_ id: UUID) {
        let wasDoing = items[id]?.isDoing == true
        items[id] = nil
        recentlyDeleted[id] = .now
        if wasDoing { updateLiveActivities() }
        storage.delete(fileURL(for: id))
        clearDelivered(id)
        scheduleSync()
    }

    // MARK: - Queries

    func children(of id: UUID) -> [Item] {
        items.values.filter { $0.parentID == id }.sorted { $0.created < $1.created }
    }

    func parent(of item: Item) -> Item? {
        item.parentID.flatMap { items[$0] }
    }

    /// Finds the item a [[link]] refers to (case-insensitive title match).
    func resolve(title: String) -> Item? {
        let key = title.lowercased()
        return items.values
            .filter { $0.title.lowercased() == key }
            .min { $0.created < $1.created }
    }

    /// Items whose notes link to this item.
    func backlinks(to item: Item) -> [Item] {
        let key = item.title.lowercased()
        guard !key.isEmpty else { return [] }
        return items.values
            .filter { $0.id != item.id && $0.outgoingLinkTitles.contains { $0.lowercased() == key } }
            .sorted { $0.updated > $1.updated }
    }

    /// True if `candidate` sits somewhere underneath `ancestor`.
    func isDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
        var current = items[candidate]?.parentID
        var hops = 0
        while let c = current, hops < 1000 {
            if c == ancestor { return true }
            current = items[c]?.parentID
            hops += 1
        }
        return false
    }

    // MARK: - Notifications

    /// Debounced: lots of edits in a row produce one reschedule.
    func scheduleSync() {
        guard schedulesNotifications else { return }
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await NotificationScheduler.shared.sync(items: Array(self.items.values))
            await SpotlightIndexer.update(self)
        }
    }

    /// Reschedule right now and wait for it (used when the app is woken in the background).
    func syncNow() async {
        guard schedulesNotifications else { return }
        syncDebounce?.cancel()
        DoingActivities.shared.reconcile(Array(items.values))
        await NotificationScheduler.shared.sync(items: Array(items.values))
        await SpotlightIndexer.update(self)
    }

    private func clearDelivered(_ id: UUID) {
        guard schedulesNotifications else { return }
        Task { await NotificationScheduler.shared.clearDelivered(for: id) }
    }
}

/// Navigation state shared with the notification delegate (tapping a nog opens its item).
@MainActor
@Observable
final class Router {
    static let shared = Router()
    var path: [UUID] = []
    /// Bumped to ask the capture field to take focus.
    var captureFocusRequest = 0

    func open(_ id: UUID) { path = [id] }

    func focusCapture() {
        path = []
        captureFocusRequest += 1
    }
}
