import Foundation
import Observation

/// Holds all items in memory and mirrors each one to `Documents/Items/<id>.md`.
@MainActor
@Observable
final class ItemStore {
    static let shared = ItemStore()

    private(set) var items: [UUID: Item] = [:]

    let folder: URL
    private let schedulesNotifications: Bool
    @ObservationIgnored private var syncDebounce: Task<Void, Never>?

    init(folder: URL? = nil, schedulesNotifications: Bool = true) {
        self.folder = folder ?? Self.defaultFolder
        self.schedulesNotifications = schedulesNotifications
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        load()
    }

    nonisolated static var defaultFolder: URL {
        URL.documentsDirectory.appending(path: "Items", directoryHint: .isDirectory)
    }

    // MARK: - Persistence

    func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [UUID: Item] = [:]
        for url in urls where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let item = ItemFile.decode(text) else { continue }
            loaded[item.id] = item
        }
        items = loaded
    }

    private func fileURL(for id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).md")
    }

    private func write(_ item: Item) {
        do {
            try Data(ItemFile.encode(item).utf8).write(to: fileURL(for: item.id), options: .atomic)
        } catch {
            print("Nag: failed to save \(item.id): \(error)")
        }
    }

    // MARK: - Mutations

    /// Quick capture: parses the text, applies the default nag, saves.
    @discardableResult
    func capture(_ text: String, parent: UUID? = nil, now: Date = .now) -> Item? {
        let parsed = CaptureParser.parse(text, defaults: NagSettings.captureDefaults, now: now)
        guard !parsed.title.isEmpty else { return nil }
        let item = Item(title: parsed.title, created: now, updated: now,
                        parentID: parent, tags: parsed.tags, reminder: parsed.reminder)
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
        if old.status != .done && item.status == .done {
            item.completed = .now
            clearDelivered(item.id)
        } else if item.status != .done {
            item.completed = nil
        }
        item.updated = .now
        items[item.id] = item
        write(item)
        scheduleSync()
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

    /// Pushes the nag start to `date` (creating a default reminder if the item had none).
    func snooze(_ id: UUID, until date: Date) {
        guard var item = items[id] else { return }
        if var r = item.reminder {
            r.start = date
            item.reminder = r
        } else {
            item.reminder = Reminder(start: date, repeatMinutes: NagSettings.repeatMinutes)
        }
        item.status = .open
        clearDelivered(id)
        update(item)
    }

    func delete(_ id: UUID) {
        items[id] = nil
        try? FileManager.default.removeItem(at: fileURL(for: id))
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
        }
    }

    /// Reschedule right now and wait for it (used when the app is woken in the background).
    func syncNow() async {
        guard schedulesNotifications else { return }
        syncDebounce?.cancel()
        await NotificationScheduler.shared.sync(items: Array(items.values))
    }

    private func clearDelivered(_ id: UUID) {
        guard schedulesNotifications else { return }
        Task { await NotificationScheduler.shared.clearDelivered(for: id) }
    }
}

/// Navigation state shared with the notification delegate (tapping a nag opens its item).
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
