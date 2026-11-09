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
    @ObservationIgnored private var pendingWrites: [UUID: Item] = [:]
    @ObservationIgnored private var writeDebounce: Task<Void, Never>?
    /// True while moving between on-phone and iCloud folders; reloads wait.
    @ObservationIgnored private var isSwitchingFolder = false

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

    /// Debounced: a burst of edits (typing) becomes one write per item.
    private func write(_ item: Item) {
        recentlyWritten[item.id] = .now
        pendingWrites[item.id] = item
        writeDebounce?.cancel()
        writeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.writePending()
        }
    }

    private func writePending() {
        let batch = pendingWrites
        pendingWrites = [:]
        for item in batch.values {
            storage.write(ItemFile.encode(item), to: fileURL(for: item.id))
        }
    }

    /// Writes everything pending and waits for the disk (call before the app may be suspended).
    func flush() async {
        writeDebounce?.cancel()
        writePending()
        await storage.flush()
    }

    func flushForTesting() {
        writeDebounce?.cancel()
        writePending()
        storage.flushSync()
    }

    // MARK: - Sidecar files (e.g. the mind map), stored and synced next to the items

    func readSidecar(_ name: String) -> Data? {
        try? Data(contentsOf: folder.appending(path: name))
    }

    func writeSidecar(_ name: String, data: Data) {
        storage.write(data: data, to: folder.appending(path: name))
    }

    // MARK: - iCloud

    /// Switches storage to iCloud Drive/Nog/Items if iCloud is available,
    /// moving any on-phone items there, then watches for changes from other devices.
    func connectToICloud() async {
        let local = StorageLocation.localFolder
        guard StorageMode.current == .iCloud else {
            await useLocalStorage()
            return
        }
        // Launch and "app became active" can both ask at once; one connect at a time.
        guard !isSwitchingFolder else { return }
        writePending()
        isSwitchingFolder = true
        defer { isSwitchingFolder = false }
        guard let cloud = await storage.resolveICloudFolder(migratingFrom: local) else {
            // iCloud is unavailable right now (signing in, Drive toggled, offline at launch).
            // Keep what's loaded and the folder we have; we'll try again next time the app is active.
            isUsingICloud = false
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
        writePending()
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
        guard !isSwitchingFolder else { return }
        let readFolder = folder
        let snapshot = await storage.readAll(in: readFolder, coordinated: isUsingICloud)
        // The folder changed (or a switch started) while we were reading: this snapshot is stale.
        guard !isSwitchingFolder, readFolder == folder else { return }
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
        let defaults = NogSettings.captureDefaults
        let parsed = CaptureParser.parse(text, defaults: defaults, now: now)
        // Typed your own rhythm ("every 5m", "!unhinged")? Then a parent's doesn't replace it.
        return add(parsed, parent: parent, ownRhythm: CaptureDefaults.differs(parsed.reminder, from: defaults), now: now)
    }

    /// Adds a parsed capture. A sub-item nogs like its parent, unless `ownRhythm`.
    @discardableResult
    func add(_ parsed: CaptureResult, parent: UUID? = nil, ownRhythm: Bool, now: Date = .now) -> Item? {
        guard !parsed.title.isEmpty else { return nil }
        var reminder = parsed.reminder
        if var r = reminder, let parentID = parent, let parentReminder = items[parentID]?.reminder,
           parentReminder.passesDown {
            if ownRhythm { r.followsParent = false } else { r = r.takingRhythm(of: parentReminder) }
            reminder = r
        }
        var item = Item(title: parsed.title, created: now, updated: now,
                        parentID: parent, tags: parsed.tags, reminder: reminder)
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
        let item = firingSoonIfPast(item, previous: nil)
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
        item = firingSoonIfPast(item, previous: old)
        item.updated = now
        items[item.id] = item
        write(item)
        if let r = item.reminder, r.passesDown,
           old.reminder.map({ !$0.sameRhythm(as: r) || !$0.passesDown }) ?? true {
            passRhythmDown(from: item)
        }
        // In a batch, notifications and Live Activities are refreshed once at the end.
        if isBatching { return }
        if old.status != item.status || old.doingSince != item.doingSince
            || old.timeboxMinutes != item.timeboxMinutes {
            updateLiveActivities()
            // Doing changes should nog (or stop nogging) right away.
            if old.status != item.status || old.timeboxMinutes != item.timeboxMinutes {
                Task { await syncNow() }
                return
            }
        }
        scheduleSync()
    }

    /// A reminder that's new, moved, or revived with a start that's already
    /// here (e.g. `@now`, "eod" after 5pm, a past time picked in the editor)
    /// fires in a few seconds instead of never (once) or a whole gap late (repeating).
    private func firingSoonIfPast(_ item: Item, previous: Item?) -> Item {
        guard var reminder = item.reminder, item.isOpen else { return item }
        let now = Date.now
        let isNew = previous?.reminder == nil
        let moved = previous?.reminder?.start != reminder.start
        let revived = previous.map { $0.status == .done || $0.status == .someday } ?? false
        guard isNew || moved || revived, reminder.start <= now.addingTimeInterval(2) else { return item }
        reminder.start = now.addingTimeInterval(5)
        var item = item
        item.reminder = reminder
        return item
    }

    // MARK: - Rhythm flowing down

    /// Open sub-items that follow this item get its rhythm (and pass it further down in turn).
    private func passRhythmDown(from item: Item) {
        guard let rhythm = item.reminder, rhythm.passesDown else { return }
        for child in children(of: item.id) where child.status != .done && child.id != item.id {
            guard let r = child.reminder, r.followsParent, !r.sameRhythm(as: rhythm) else { continue }
            var updated = child
            updated.reminder = r.takingRhythm(of: rhythm)
            update(updated)
        }
    }

    // MARK: - Batches

    private var isBatching = false

    /// Applies many changes, then reschedules notifications once (multi-select edits).
    func batch(_ body: () -> Void) {
        let wasBatching = isBatching
        isBatching = true
        body()
        isBatching = wasBatching
        guard !wasBatching else { return }
        updateLiveActivities()
        Task { await syncNow() }
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
        WidgetSync.publish(Array(items.values))
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
    /// While you're doing it, snooze means "more time" (extends the timebox).
    /// Finished items aren't snoozed.
    func snooze(_ id: UUID, until date: Date) {
        guard var item = items[id] else { return }
        if item.isDoing {
            extend(id, minutes: max(5, Int((date.timeIntervalSinceNow / 60).rounded())))
            return
        }
        guard item.status != .done else { return }
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
        pendingWrites[id] = nil
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
            WidgetSync.publish(Array(self.items.values))
            await NotificationScheduler.shared.sync(items: Array(self.items.values))
            await SpotlightIndexer.update(self)
            // Siri learns current item titles for "Start …" / "Mark … done".
            NogShortcuts.updateAppShortcutParameters()
        }
    }

    /// Reschedule right now and wait for it (used when the app is woken in the background).
    func syncNow() async {
        guard schedulesNotifications else { return }
        syncDebounce?.cancel()
        DoingActivities.shared.reconcile(Array(items.values))
        WidgetSync.publish(Array(items.values))
        await NotificationScheduler.shared.sync(items: Array(items.values))
        await SpotlightIndexer.update(self)
        NogShortcuts.updateAppShortcutParameters()
    }

    private func clearDelivered(_ id: UUID) {
        guard schedulesNotifications else { return }
        Task { await NotificationScheduler.shared.clearDelivered(for: id) }
    }
}

enum AppTab: Hashable {
    case capture, agenda, nogs, map
}

/// Navigation state shared with the notification delegate (tapping a nog opens its item).
@MainActor
@Observable
final class Router {
    static let shared = Router()
    var tab: AppTab = .capture
    var capturePath: [UUID] = []
    var agendaPath: [UUID] = []
    /// The Nogs tab's stack.
    var path: [UUID] = []
    var mapPath: [UUID] = []
    /// Bumped to ask the capture field to take focus.
    var captureFocusRequest = 0
    /// Asks the app to show the Silence choices (from the app icon's "Silence for…").
    var showSilenceSheet = false

    /// Opens an item on the current tab's stack.
    func push(_ id: UUID) {
        switch tab {
        case .capture: capturePath.append(id)
        case .agenda: agendaPath.append(id)
        case .nogs: path.append(id)
        case .map: mapPath.append(id)
        }
    }

    /// Goes to an item's parent: back, if you came from it; otherwise opens it.
    func goUp(to parent: UUID) {
        func up(_ path: inout [UUID]) {
            if path.count >= 2, path[path.count - 2] == parent { path.removeLast() } else { path.append(parent) }
        }
        switch tab {
        case .capture: up(&capturePath)
        case .agenda: up(&agendaPath)
        case .nogs: up(&path)
        case .map: up(&mapPath)
        }
    }

    /// From a notification or Siri: show the item in the Nogs tab.
    func open(_ id: UUID) {
        tab = .nogs
        path = [id]
    }

    func focusCapture() {
        tab = .capture
        capturePath = []
        captureFocusRequest += 1
    }
}
