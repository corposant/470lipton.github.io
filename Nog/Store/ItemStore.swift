import UserNotifications
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
    /// The waiting sync also needs to reschedule nogs (not just widgets and Spotlight).
    @ObservationIgnored private var pendingSyncIncludesNogs = false
    /// Titles Siri last learned, so it's only told again when they change.
    @ObservationIgnored private var shortcutTitles: Set<String>?
    @ObservationIgnored private var isWatchingPaused = false
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var hasConnected = false
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
        // Through `storage`, so later reloads only re-read files that changed.
        let snapshot = storage.readAllSync(in: folder, coordinated: false)
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

    // MARK: - Voice notes, stored and synced next to the items

    /// Moves a finished recording into the folder and lists it on the item.
    func attachVoiceNote(_ recording: VoiceRecording, to id: UUID) {
        guard var item = items[id], VoiceNote.isValidFile(recording.file) else {
            try? FileManager.default.removeItem(at: recording.url)
            return
        }
        storage.move(recording.url, to: folder.appending(path: recording.file))
        item.voiceNotes.append(VoiceNote(file: recording.file, seconds: recording.seconds))
        update(item)
    }

    func removeVoiceNote(_ file: String, from id: UUID) {
        guard var item = items[id], item.voiceNotes.contains(where: { $0.file == file }) else { return }
        item.voiceNotes.removeAll { $0.file == file }
        update(item)
        if VoiceNote.isValidFile(file) { storage.delete(folder.appending(path: file)) }
    }

    /// The recording's audio. From iCloud, this waits for it to download.
    func voiceNoteData(_ file: String) async -> Data? {
        guard VoiceNote.isValidFile(file) else { return nil }
        // Always coordinated: the folder may be iCloud's before the connect at launch finishes.
        return await storage.readData(at: folder.appending(path: file), coordinated: true)
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
            if snapshot.folderReadable {
                for item in items.values where !snapshot.presentIDs.contains(item.id) { write(item) }
            }
        }
        await reloadFromDisk()
        startWatching()
    }

    /// Catches up with the disk (connecting to iCloud first if that hasn't worked yet) and
    /// reschedules. Launch and "app became active" both ask at once; overlapping calls share one run.
    func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // First time, or iCloud was unavailable earlier (signing in, offline at launch): (re)connect.
            if !self.hasConnected || (StorageMode.current == .iCloud && !self.isUsingICloud) {
                self.hasConnected = true
                await self.connectToICloud() // reloads from disk itself
            } else {
                await self.reloadFromDisk()
            }
            await self.syncNow()
        }
        refreshing = task
        await task.value
        refreshing = nil
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
        let previous = folder
        folder = local
        for item in items.values { write(item) }
        storage.copyFiles(items.values.flatMap { $0.voiceNotes.map(\.file) }.filter(VoiceNote.isValidFile),
                          from: previous, to: local)
        await flush()
    }

    private func stopWatching() {
        query?.stop()
        query = nil
        isWatchingPaused = false
        for observer in queryObservers { NotificationCenter.default.removeObserver(observer) }
        queryObservers = []
    }

    /// Merges what's on disk (possibly changed by another device) into memory.
    func reloadFromDisk() async {
        guard !isSwitchingFolder else { return }
        let readFolder = folder
        let signpost = Perf.signposter.beginInterval("Reload from disk")
        let snapshot = await storage.readAll(in: readFolder, coordinated: isUsingICloud)
        Perf.signposter.endInterval("Reload from disk", signpost,
                                    "\(snapshot.filesRead) of \(snapshot.presentIDs.count) files read")
        // The folder changed (or a switch started) while we were reading: this snapshot is stale.
        guard !isSwitchingFolder, readFolder == folder else { return }
        // Couldn't even list the folder: keep everything as it is and try again next time.
        guard snapshot.folderReadable else { return }
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
        isWatchingPaused = false
    }

    /// In the background nothing is on screen, so iCloud changes wait until the app is back
    /// (becoming active reloads anyway).
    func pauseWatching(_ paused: Bool) {
        guard let query, paused != isWatchingPaused else { return }
        isWatchingPaused = paused
        if paused { query.disableUpdates() } else { query.enableUpdates() }
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
        item.urgent = parsed.urgent
        item.recurrence = reminder == nil ? nil : parsed.recurrence
        item.place = parsed.place
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
        // A recurring item isn't finished by Done: it moves on to its next time.
        var rolledTo: Date?
        if old.status != .done && item.status == .done, let next = nextOccurrence(of: item, now: now) {
            item.reminder?.start = next
            item.reminder?.rampSince = nil // a fresh occurrence: Balanced starts over
            item.status = .open
            item.lastDone = now
            item.timesDone += 1
            clearDelivered(item.id)
            rolledTo = next
        }
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
            item.checkInMinutes = nil
        }
        // Filed under a different parent: its old place among siblings means nothing there.
        if old.parentID != item.parentID { item.position = nil }
        item = firingSoonIfPast(item, previous: old)
        item.updated = now
        items[item.id] = item
        write(item)
        if let rolledTo { resetSubItems(of: item.id, for: rolledTo) }
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
        // Typing (title or notes) waits for a longer pause, so a sentence is one sync, not ten.
        // Notes and tags don't change any nog, so those skip rescheduling entirely.
        let isTyping = old.title != item.title || old.body != item.body
        scheduleSync(nogs: item.changesNogs(from: old), after: isTyping ? .seconds(2) : .milliseconds(400))
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

    // MARK: - Recurring items

    /// Where a recurring item goes when it's done (nil for a one-off, or one with no reminder).
    private func nextOccurrence(of item: Item, now: Date) -> Date? {
        guard let recurrence = item.recurrence, let start = item.reminder?.start else { return nil }
        return recurrence.next(after: now, from: start)
    }

    /// Skips this time of a recurring item without counting it as done.
    func skipOccurrence(_ id: UUID) {
        guard var item = items[id], let next = nextOccurrence(of: item, now: .now) else { return }
        if item.isDoing { item.status = .open }
        item.reminder?.start = next
        item.reminder?.rampSince = nil // a fresh occurrence: Balanced starts over
        clearDelivered(id)
        update(item)
        resetSubItems(of: id, for: next)
    }

    /// A routine's steps (sub-nogs) come back with it: finished ones reopen for next time.
    private func resetSubItems(of id: UUID, for next: Date) {
        for child in children(of: id) where child.status == .done {
            var reopened = child
            reopened.status = .open
            if var r = reopened.reminder, r.start < next {
                r.start = next
                r.rampSince = nil
                reopened.reminder = r
            }
            update(reopened)
        }
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

    /// The starter timer ▶︎ uses: two minutes (Settings › Doing › Starter), for every nog.
    func suggestedTimebox(for id: UUID) -> TimeboxSuggestion {
        TimeboxAdvisor.suggest(defaultMinutes: NogSettings.timeboxMinutes)
    }

    /// What ▶︎ on this nog actually starts: its first unfinished sub-nog (the small physical
    /// step), all the way down, or the nog itself when it has none.
    func startTarget(for id: UUID) -> UUID {
        var current = id
        var seen: Set<UUID> = []
        while seen.insert(current).inserted, items[current]?.isDoing != true,
              let next = children(of: current).first(where: { $0.status == .open || $0.status == .doing }) {
            current = next.id
        }
        return current
    }

    /// The sub-nog being worked on under this nog, if any (shown on the parent's page).
    func doingDescendant(of id: UUID) -> Item? {
        var queue = children(of: id)
        var seen: Set<UUID> = [id]
        while !queue.isEmpty {
            let child = queue.removeFirst()
            guard seen.insert(child.id).inserted else { continue }
            if child.isDoing { return child }
            queue += children(of: child.id)
        }
        return nil
    }

    /// Starts working on an item: its first unfinished sub-nog if it has any. `timebox` nil = open-ended.
    func start(_ id: UUID, timebox: Int?) {
        let target = startTarget(for: id)
        if target != id {
            // That step is already under way: leave its timer alone.
            if items[target]?.isDoing == true { return }
            return start(target, timebox: timebox)
        }
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
    /// Once the starter has run out the session is counting up, with nothing left to extend:
    /// growing the timer then would turn it back into a countdown and play the chime again.
    func extend(_ id: UUID, minutes: Int) {
        guard var item = items[id], item.isDoing, let since = item.doingSince else { return }
        if item.isCountingUp() {
            clearDelivered(id)
            return
        }
        let elapsed = Int(Date.now.timeIntervalSince(since) / 60)
        let currentEnd = item.timeboxMinutes ?? elapsed
        item.timeboxMinutes = max(currentEnd, elapsed) + minutes
        clearDelivered(id)
        update(item)
    }

    /// "Done for now": stops this session (its time is logged) without finishing; the item goes
    /// back to Open. Work happened, so the rest of today's nogs can wait: it comes back tomorrow
    /// (at its own time for a once-a-day rhythm, otherwise in the morning). Urgent ones (flagged
    /// urgent, or ringing like an alarm) keep their rhythm. Returns the seconds this session logged.
    ///
    /// ▶︎ on a nog starts its first sub-nog, so the nogs above a step wait until tomorrow too:
    /// otherwise the parent you pressed ▶︎ on would carry on nogging the same afternoon.
    @discardableResult
    func stopDoing(_ id: UUID, now: Date = .now, calendar: Calendar = .current) -> TimeInterval {
        guard var item = items[id], item.isDoing else { return 0 }
        let logged = item.doingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        batch {
            item.status = .open
            holdUntilTomorrow(&item, now: now, calendar: calendar)
            update(item)
            var seen: Set<UUID> = [id]
            var next = item.parentID
            while let parentID = next, seen.insert(parentID).inserted, var parent = items[parentID] {
                next = parent.parentID
                guard parent.isOpen, holdUntilTomorrow(&parent, now: now, calendar: calendar) else { continue }
                update(parent)
            }
        }
        return logged
    }

    /// Moves a nog's next reminder to tomorrow if `resumeDate` says so. True if it moved.
    @discardableResult
    private func holdUntilTomorrow(_ item: inout Item, now: Date, calendar: Calendar) -> Bool {
        guard let resume = Self.resumeDate(for: item, now: now, calendar: calendar), let r = item.reminder else {
            return false
        }
        item.reminder = r.moved(to: resume)
        clearDelivered(item.id)
        return true
    }

    /// When a nog stopped with "Done for now" next nogs, if its next nog would otherwise
    /// come later today. nil = leave its reminder as it is.
    nonisolated static func resumeDate(for item: Item, now: Date, calendar: Calendar = .current) -> Date? {
        // Only a nog that's already nogging is held. One that hasn't started yet ("call at 3 PM",
        // asked for at 1) keeps the time you gave it.
        guard let r = item.reminder, r.isActive(at: now), !r.alarm, !item.urgent, item.recurrence == nil,
              let next = r.nextFire(after: now), calendar.isDate(next, inSameDayAs: now),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        else { return nil }
        if let gap = r.repeatMinutes, gap >= 1440,
           let sameTime = r.nextFire(after: tomorrow.addingTimeInterval(-1)) {
            return sameTime
        }
        return NogSettings.nextMorning(after: tomorrow.addingTimeInterval(-1), minutes: r.morningMinutes)
    }

    /// Flags (or unflags) a nog as urgent.
    func setUrgent(_ id: UUID, _ urgent: Bool) {
        guard var item = items[id], item.urgent != urgent else { return }
        item.urgent = urgent
        update(item)
    }

    /// Long press on the timer: how often "still on it?" comes for this session (0 = off,
    /// nil = the Settings default).
    func setCheckIn(_ id: UUID, minutes: Int?) {
        guard var item = items[id], item.isDoing else { return }
        item.checkInMinutes = minutes
        clearDelivered(id)
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
        if let r = item.reminder {
            item.reminder = r.moved(to: date)
        } else {
            item.reminder = Reminder(start: date, repeatMinutes: NogSettings.repeatMinutes, curve: NogSettings.curve,
                                     silent: NogSettings.silent)
        }
        item.status = .open
        clearDelivered(id)
        update(item)
    }

    // MARK: - Notification buttons

    /// "Gentler": the next quieter profile (Unhinged → Building → Steady → Easing → Whisper),
    /// starting over from now so the new rhythm begins at its own first gap.
    func makeGentler(_ id: UUID, now: Date = .now) {
        guard var item = items[id], item.isOpen, let r = item.reminder,
              let quieter = NogProfile.matching(r)?.gentler else { return }
        var gentler = quieter.apply(to: r)
        gentler.start = quieter.firstStart(from: now)
        if item.parentID != nil { gentler.followsParent = false }
        item.reminder = gentler
        clearDelivered(id)
        update(item)
    }

    /// "Skip today": nothing more today, back at its usual time on its next day.
    /// A recurring to-do skips to its next occurrence instead.
    func skipToday(_ id: UUID, now: Date = .now, calendar: Calendar = .current) {
        guard let item = items[id] else { return }
        if item.recurrence != nil { return skipOccurrence(id) }
        guard let r = item.reminder,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let next = r.nextFire(after: tomorrow.addingTimeInterval(-1)) else { return }
        snooze(id, until: next)
    }

    /// "Later…": a typed time ("20m", "4pm", "tomorrow") and/or profile ("!hush").
    /// Anything it can't read snoozes for the usual length, so the nog is never lost.
    func nogLater(_ id: UUID, reply: String, now: Date = .now) {
        guard var item = items[id] else { return }
        let later = LaterReply.parse(reply, now: now)
        if let profile = later.profile, item.isOpen {
            var r = profile.apply(to: item.reminder ?? profile.reminder(from: now))
            r.start = later.start ?? profile.firstStart(from: now)
            if item.parentID != nil { r.followsParent = false }
            item.reminder = r
            clearDelivered(id)
            update(item)
            return
        }
        let minutes = NogSettings.snoozeLength(for: item)
        snooze(id, until: later.start ?? now.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func delete(_ id: UUID) {
        let wasDoing = items[id]?.isDoing == true
        for note in items[id]?.voiceNotes ?? [] where VoiceNote.isValidFile(note.file) {
            storage.delete(folder.appending(path: note.file))
        }
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
        items.values.filter { $0.parentID == id }.sorted(by: Item.siblingOrder)
    }

    /// Puts a nog's sub-nogs in a new order (a drag in the detail view). Every sibling
    /// gets a position, so the order holds as more are added below.
    func moveChildren(of parentID: UUID, from source: IndexSet, to destination: Int) {
        setOrder(Item.reordered(children(of: parentID), from: source, to: destination))
    }

    /// Moves one sub-nog up (-1) or down (+1) among its siblings, for VoiceOver's
    /// Move up / Move down. Returns its new place, 1-based, and how many there are.
    @discardableResult
    func moveChild(_ id: UUID, by offset: Int) -> (place: Int, of: Int)? {
        guard let parentID = items[id]?.parentID else { return nil }
        let kids = children(of: parentID)
        guard let from = kids.firstIndex(where: { $0.id == id }) else { return nil }
        let to = from + offset
        guard kids.indices.contains(to) else { return nil }
        setOrder(Item.reordered(kids, from: [from], to: offset > 0 ? to + 1 : to))
        return (to + 1, kids.count)
    }

    /// Order is bookkeeping, not an edit: `updated` stays put so lists sorted by
    /// recent change don't jump, and no nog changes, so notifications aren't rebuilt.
    private func setOrder(_ ordered: [Item]) {
        var changed = false
        for (index, kid) in ordered.enumerated() where items[kid.id]?.position != index {
            guard var current = items[kid.id] else { continue }
            current.position = index
            items[kid.id] = current
            write(current)
            changed = true
        }
        if changed { scheduleSync(nogs: false) }
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
    /// `nogs: false` when nothing a nog is built from changed (notes, tags): widgets and
    /// Spotlight still update, but notifications and alarms are left alone.
    func scheduleSync(nogs: Bool = true, after delay: Duration = .milliseconds(400)) {
        guard schedulesNotifications else { return }
        pendingSyncIncludesNogs = pendingSyncIncludesNogs || nogs
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.runPendingSync()
        }
    }

    private func runPendingSync() async {
        let nogs = pendingSyncIncludesNogs
        pendingSyncIncludesNogs = false
        syncDebounce = nil
        let signpost = Perf.signposter.beginInterval("Sync")
        defer { Perf.signposter.endInterval("Sync", signpost) }
        PlaceBook.shared.restoreIfEmpty(from: self)
        await nogFromPlaceArrivals()
        let all = Array(items.values)
        WidgetSync.publish(all)
        if nogs { await NotificationScheduler.shared.sync(items: all) }
        await SpotlightIndexer.update(self)
        updateShortcutsIfTitlesChanged()
    }

    /// Runs a sync that's still waiting out its debounce (the app is going to the background).
    func syncIfPending() async {
        guard syncDebounce != nil else { return }
        syncDebounce?.cancel()
        await runPendingSync()
    }

    /// Reschedule right now and wait for it (used when the app is woken in the background).
    func syncNow() async {
        guard schedulesNotifications else { return }
        syncDebounce?.cancel()
        syncDebounce = nil
        pendingSyncIncludesNogs = false
        let signpost = Perf.signposter.beginInterval("Sync")
        defer { Perf.signposter.endInterval("Sync", signpost) }
        let all = Array(items.values)
        DoingActivities.shared.reconcile(all)
        WidgetSync.publish(all)
        await NotificationScheduler.shared.sync(items: all)
        await SpotlightIndexer.update(self)
        updateShortcutsIfTitlesChanged()
    }

    /// A place nog went off ("You're at Home"): from then on the item nogs like any other until
    /// it's done, starting one gap later (you've just been told).
    private func nogFromPlaceArrivals() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let arrived = Set(delivered
            .filter { $0.request.identifier.hasPrefix(NogPlanner.placePrefix) }
            .compactMap { ($0.request.content.userInfo[NotificationScheduler.itemIDKey] as? String)
                .flatMap(UUID.init(uuidString:)) })
        for id in arrived {
            guard var item = items[id], item.isOpen, item.place != nil else { continue }
            var reminder = item.reminder ?? NogSettings.defaultReminderFromNow
            let gap = reminder.repeatMinutes ?? NogSettings.repeatMinutes ?? NogSettings.defaultRepeat
            reminder.start = Date.now.addingTimeInterval(TimeInterval(gap * 60))
            item.reminder = reminder
            item.place = nil
            update(item)
        }
    }

    /// Siri learns current item titles for "Start …" / "Mark … done"; only tell it when they change.
    private func updateShortcutsIfTitlesChanged() {
        let titles = Set(items.values.map(\.title))
        guard titles != shortcutTitles else { return }
        shortcutTitles = titles
        NogShortcuts.updateAppShortcutParameters()
    }

    private func clearDelivered(_ id: UUID) {
        guard schedulesNotifications else { return }
        Task { await NotificationScheduler.shared.clearDelivered(for: id) }
    }
}

enum AppTab: Hashable {
    case capture, agenda, nogs, map, search
}

/// Navigation state shared with the notification delegate (tapping a nog opens its item).
@MainActor
@Observable
final class Router {
    static let shared = Router()
    var tab: AppTab = .capture
    var capturePath: [UUID] = []
    var agendaPath: [UUID] = []
    /// The List tab's stack.
    var path: [UUID] = []
    var mapPath: [UUID] = []
    /// The Search tab's stack.
    var searchPath: [UUID] = []
    /// Bumped to ask the capture field to take focus.
    var captureFocusRequest = 0
    /// Asks the app to show the Silence choices (from the app icon's "Silence for…").
    var showSilenceSheet = false
    /// Shows Settings. Every tab's gear (SettingsButton) sets this; RootView shows the sheet.
    var showSettings = false

    /// Opens an item on the current tab's stack.
    func push(_ id: UUID) {
        switch tab {
        case .capture: capturePath.append(id)
        case .agenda: agendaPath.append(id)
        case .nogs: path.append(id)
        case .map: mapPath.append(id)
        case .search: searchPath.append(id)
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
        case .search: up(&searchPath)
        }
    }

    /// From a notification or Siri: show the item in the List tab.
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
