import AppIntents
import CoreSpotlight
import Foundation
import GeoToolbox

// iOS 27 App Schemas — the `.reminders` domain.
//
// Adopting these lets Siri and Apple Intelligence use Nog like a native
// reminders app: "Remind me in Nog to call mom tomorrow at 3",
// "Add milk to my Groceries list in Nog", "Mark this as done",
// "Set the due date for this reminder to Friday".
//
// Mapping: every Nog item is a reminder. An item used as a parent is a
// "list", so a project's sub-items are that list's reminders. Top-level items
// live in a virtual "Inbox" list.

// MARK: - Reminder

@AppEntity(schema: .reminders.reminder)
struct ReminderEntity: IndexedEntity, SyncableEntity {
    static let defaultQuery = ReminderEntityQuery()

    let id: UUID

    var title: String
    @Property(indexingKey: \.textContent)
    var note: AttributedString?
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool
    var isFlagged: Bool?
    var creationDate: Date?
    var completionDate: Date?
    var list: ListEntity
    var locationTrigger: LocationTriggerEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: dueDate.flatMap { Calendar.current.date(from: $0) }
                .map { "\($0.formatted(date: .abbreviated, time: .shortened))" },
            image: .init(systemName: isCompleted ? "checkmark.circle.fill" : "bell.badge"))
    }

    struct ReminderEntityQuery: EntityStringQuery {
        func entities(for identifiers: [UUID]) async throws -> [ReminderEntity] {
            await MainActor.run {
                let store = ItemStore.shared
                let found: [Item] = identifiers.compactMap { store.items[$0] }
                return found.map { ReminderEntity(item: $0, store: store) }
            }
        }

        func entities(matching string: String) async throws -> [ReminderEntity] {
            await MainActor.run {
                let store = ItemStore.shared
                var hits: [Item] = store.items.values.filter { $0.title.localizedStandardContains(string) }
                hits.sort { $0.updated > $1.updated }
                return hits.prefix(20).map { ReminderEntity(item: $0, store: store) }
            }
        }

        func suggestedEntities() async throws -> [ReminderEntity] {
            await MainActor.run {
                let store = ItemStore.shared
                var open: [Item] = store.items.values.filter { $0.isOpen }
                open.sort { a, b in
                    let x: Date = a.reminder?.start ?? .distantFuture
                    let y: Date = b.reminder?.start ?? .distantFuture
                    return x < y
                }
                return open.prefix(20).map { ReminderEntity(item: $0, store: store) }
            }
        }
    }
}

extension ReminderEntity {
    @MainActor
    init(item: Item, store: ItemStore) {
        id = item.id
        title = item.title
        note = item.body.isEmpty ? nil : AttributedString(item.body)
        tags = Set(item.tags)
        urls = []
        dueDate = item.reminder.map {
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0.start)
        }
        recurrence = item.recurrence.map(Calendar.RecurrenceRule.nog(_:))
            ?? item.reminder?.repeatMinutes.map(Calendar.RecurrenceRule.nog(minutes:))
        isCompleted = item.status == .done
        isFlagged = item.reminder?.alarm
        creationDate = item.created
        completionDate = item.completed
        list = store.parent(of: item).map(ListEntity.init(item:)) ?? .inbox
        locationTrigger = nil
    }
}

// MARK: - List (an item that holds other items)

@AppEntity(schema: .reminders.list)
struct ListEntity {
    static let defaultQuery = ListEntityQuery()

    /// Top-level items belong to this virtual list.
    static let inboxID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let inbox = ListEntity(id: inboxID, name: "Inbox")

    let id: UUID

    var name: String
    var type: ListType

    /// The schema macro turns these into entity properties, so set them one by one.
    init(id: UUID, name: String, type: ListType = .standard) {
        self.id = id
        self.name = name
        self.type = type
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "list.bullet"))
    }

    struct ListEntityQuery: EntityStringQuery {
        func entities(for identifiers: [UUID]) async throws -> [ListEntity] {
            await MainActor.run {
                identifiers.compactMap { (id: UUID) -> ListEntity? in
                    if id == ListEntity.inboxID { return ListEntity.inbox }
                    guard let item = ItemStore.shared.items[id] else { return nil }
                    return ListEntity(item: item)
                }
            }
        }

        func entities(matching string: String) async throws -> [ListEntity] {
            await MainActor.run {
                let open: [Item] = ItemStore.shared.items.values.filter { $0.status != .done }
                let hits: [Item] = open.filter { $0.title.localizedStandardContains(string) }
                let matches: [ListEntity] = hits.map { ListEntity(item: $0) }
                if "Inbox".localizedStandardContains(string) { return [ListEntity.inbox] + matches }
                return matches
            }
        }

        func suggestedEntities() async throws -> [ListEntity] {
            await MainActor.run {
                let store = ItemStore.shared
                let parentIDs: Set<UUID> = Set(store.items.values.compactMap { $0.parentID })
                var parents: [Item] = parentIDs.compactMap { store.items[$0] }
                parents = parents.filter { $0.status != .done }
                parents.sort { $0.updated > $1.updated }
                let lists: [ListEntity] = parents.map { ListEntity(item: $0) }
                return [ListEntity.inbox] + lists
            }
        }
    }
}

extension ListEntity {
    init(item: Item) {
        self.init(id: item.id, name: item.title)
    }

    /// The Nog item this list maps to (nil for the Inbox).
    var parentID: UUID? { id == Self.inboxID ? nil : id }
}

@AppEnum(schema: .reminders.listType)
enum ListType: String {
    case standard

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .standard: "Standard"
    ]
}

// MARK: - Required by the schema; Nog doesn't do location reminders (yet)

@AppEntity(schema: .reminders.locationTrigger)
struct LocationTriggerEntity {
    static let defaultQuery = LocationTriggerEntityQuery()

    let id: String

    var place: GeoToolbox.PlaceDescriptor
    var event: LocationTriggerEvent

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(event.rawValue.capitalized)")
    }

    struct LocationTriggerEntityQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [LocationTriggerEntity] { [] }
        func entities(matching string: String) async throws -> [LocationTriggerEntity] { [] }
    }
}

@AppEnum(schema: .reminders.locationTriggerEvent)
enum LocationTriggerEvent: String {
    case arrive
    case depart

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .arrive: "Arrive",
        .depart: "Depart"
    ]
}

// MARK: - Intents

/// "Remind me in Nog to …". Falls back to Nog's natural-language parser and
/// default nog when Siri doesn't supply a due date.
@AppIntent(schema: .reminders.createReminder)
struct CreateReminderIntent {
    var title: String
    var list: ListEntity?
    var note: AttributedString?
    var isFlagged: Bool?
    var images: [IntentFile]
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var locationTrigger: LocationTriggerEntity?
    var section: SectionEntity?

    @MainActor
    func perform() async throws -> some ReturnsValue<ReminderEntity> & ProvidesDialog {
        let store = ItemStore.shared
        guard var item = store.capture(title, parent: list?.parentID) else {
            throw NogIntentError.emptyTitle
        }
        if let note {
            item.body = String(note.characters)
        }
        if !urls.isEmpty {
            item.body += (item.body.isEmpty ? "" : "\n\n") + urls.map(\.absoluteString).joined(separator: "\n")
        }
        item.tags = Array(Set(item.tags).union(tags)).sorted()
        if let date = dueDate.flatMap(Calendar.nogDate(from:)) {
            var reminder = item.reminder ?? NogSettings.defaultReminderFromNow
            reminder.start = date
            item.reminder = reminder
        }
        if let comesBack = recurrence?.nogRecurrence(from: item.reminder?.start ?? .now) {
            // Daily, weekly, monthly, yearly: a to-do that comes back after it's done.
            if item.reminder == nil { item.reminder = NogSettings.defaultReminderFromNow }
            item.recurrence = comesBack
        } else if let minutes = recurrence?.nogMinutes {
            var reminder = item.reminder ?? NogSettings.defaultReminderFromNow
            reminder.repeatMinutes = minutes
            item.reminder = reminder
        }
        if isFlagged == true { item.reminder?.alarm = true }
        store.update(item)
        await store.syncNow()
        await store.flush()

        let saved = store.items[item.id] ?? item
        return .result(
            value: ReminderEntity(item: saved, store: store),
            dialog: IntentDialog(full: "Got it. I'll nog you about \(saved.title).", supporting: "Nogging"))
    }
}

/// "Mark this as done", "Set the due date for this reminder to tomorrow".
@AppIntent(schema: .reminders.updateReminder)
struct UpdateReminderIntent {
    var target: ReminderEntity
    var title: String?
    var note: AttributedString?
    var tags: Set<String>?
    var urls: [URL]?
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool?
    var isFlagged: Bool?
    var list: ListEntity?
    var locationTrigger: LocationTriggerEntity?

    @MainActor
    func perform() async throws -> some ReturnsValue<ReminderEntity> {
        let store = ItemStore.shared
        guard var item = store.items[target.id] else { throw NogIntentError.notFound }
        if let title, !title.isEmpty { item.title = title }
        if let note { item.body = String(note.characters) }
        if let tags { item.tags = tags.sorted() }
        if let date = dueDate.flatMap(Calendar.nogDate(from:)) {
            var reminder = item.reminder ?? NogSettings.defaultReminderFromNow
            reminder.start = date
            item.reminder = reminder
            if item.status == .done { item.status = .open }
        }
        if let comesBack = recurrence?.nogRecurrence(from: item.reminder?.start ?? .now) {
            // Daily, weekly, monthly, yearly: a to-do that comes back after it's done.
            if item.reminder == nil { item.reminder = NogSettings.defaultReminderFromNow }
            item.recurrence = comesBack
        } else if let minutes = recurrence?.nogMinutes {
            var reminder = item.reminder ?? NogSettings.defaultReminderFromNow
            reminder.repeatMinutes = minutes
            item.reminder = reminder
        }
        if let isFlagged, item.reminder != nil { item.reminder?.alarm = isFlagged }
        // Never move an item inside itself or one of its own sub-items.
        if let list, list.id != item.id, !(list.parentID.map { store.isDescendant($0, of: item.id) } ?? false) {
            item.parentID = list.parentID
        }
        if let isCompleted { item.status = isCompleted ? .done : .open }
        store.update(item)
        await store.syncNow()
        await store.flush()
        return .result(value: ReminderEntity(item: store.items[item.id] ?? item, store: store))
    }
}

@AppIntent(schema: .reminders.deleteReminders)
struct DeleteRemindersIntent: DeleteIntent {
    var entities: [ReminderEntity]

    @MainActor
    func perform() async throws -> some IntentResult {
        for entity in entities { ItemStore.shared.delete(entity.id) }
        await ItemStore.shared.syncNow()
        await ItemStore.shared.flush()
        return .result()
    }
}

/// "Create a list called Groceries in Nog" → a new (reminder-less) parent item.
@AppIntent(schema: .reminders.createList)
struct CreateListIntent {
    var type: ListType
    var name: String

    @MainActor
    func perform() async throws -> some ReturnsValue<ListEntity> {
        let item = ItemStore.shared.createIdea(title: name)
        await ItemStore.shared.flush()
        return .result(value: ListEntity(item: item))
    }
}

// Sections are referenced by createReminder; Nog has none, so the query is empty.
@AppEntity(schema: .reminders.section)
struct SectionEntity {
    static let defaultQuery = SectionEntityQuery()

    let id: String

    var name: String
    var list: ListEntity

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    struct SectionEntityQuery: EntityStringQuery {
        func entities(for identifiers: [String]) async throws -> [SectionEntity] { [] }
        func entities(matching string: String) async throws -> [SectionEntity] { [] }
    }
}

enum NogIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyTitle, notFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyTitle: "There was nothing to remind you about."
        case .notFound: "I couldn't find that item in Nog."
        }
    }
}

// MARK: - Siri dates

extension Calendar {
    /// Siri's due dates often carry only a day ("Friday"); those mean 9 AM, like typed captures.
    static func nogDate(from components: DateComponents) -> Date? {
        var components = components
        if components.hour == nil {
            components.hour = 9
            components.minute = 0
        }
        return Calendar.current.date(from: components)
    }
}

// MARK: - Recurrence ↔ repeat minutes

extension Calendar.RecurrenceRule {
    static func nog(minutes: Int) -> Calendar.RecurrenceRule {
        if minutes % 1440 == 0 { return .init(calendar: .current, frequency: .daily, interval: minutes / 1440) }
        if minutes % 60 == 0 { return .init(calendar: .current, frequency: .hourly, interval: minutes / 60) }
        return .init(calendar: .current, frequency: .minutely, interval: minutes)
    }

    /// A Recurrence for Nog's own rules.
    static func nog(_ recurrence: Recurrence) -> Calendar.RecurrenceRule {
        switch recurrence.rule {
        case .days(let n): .init(calendar: .current, frequency: .daily, interval: n)
        case .weeks(let n): .init(calendar: .current, frequency: .weekly, interval: n)
        case .weekdays: .init(calendar: .current, frequency: .weekly, interval: 1)
        case .monthly: .init(calendar: .current, frequency: .monthly, interval: 1)
        case .yearly: .init(calendar: .current, frequency: .yearly, interval: 1)
        }
    }

    /// Day-or-longer rules become a Nog that comes back after it's done.
    func nogRecurrence(from start: Date) -> Recurrence? {
        let c = Calendar.current.dateComponents([.month, .day], from: start)
        switch frequency {
        case .daily: return Recurrence(.days(max(1, interval)))
        case .weekly: return Recurrence(.weeks(max(1, interval)))
        case .monthly: return Recurrence(.monthly(day: c.day ?? 1))
        case .yearly: return Recurrence(.yearly(month: c.month ?? 1, day: c.day ?? 1))
        default: return nil
        }
    }

    var nogMinutes: Int? {
        switch frequency {
        case .minutely: interval
        case .hourly: interval * 60
        case .daily: interval * 1440
        case .weekly: interval * 10_080
        default: nil
        }
    }
}

// MARK: - Spotlight semantic index

/// Keeps Spotlight's semantic index (which Siri searches) in step with Nog.
/// Only items that changed since the last pass are re-indexed. What was indexed is
/// remembered across launches, so a cold launch doesn't re-index every item, and items
/// deleted while the app was closed (say, on another device) are still taken out.
@MainActor
enum SpotlightIndexer {
    /// Bump when `ReminderEntity`'s indexed contents change, to re-index everything once.
    private static let version = 1

    /// id → `updated` at the time it was indexed
    private static var indexed: [UUID: Date] = loadIndexed()

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "spotlight-indexed-v\(version).json")
    }

    static func update(_ store: ItemStore) async {
        // Item files keep milliseconds, so an item read back after a relaunch can differ
        // from the in-memory time it was indexed at by less than that.
        let changed = store.items.values.filter { item in
            indexed[item.id].map { abs($0.timeIntervalSince(item.updated)) >= 0.001 } ?? true
        }
        let removed = Set(indexed.keys).subtracting(store.items.keys)
        guard !changed.isEmpty || !removed.isEmpty else { return }
        do {
            if !changed.isEmpty {
                try await CSSearchableIndex.default()
                    .indexAppEntities(changed.map { ReminderEntity(item: $0, store: store) })
            }
            if !removed.isEmpty {
                try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: Array(removed), ofType: ReminderEntity.self)
            }
            for item in changed { indexed[item.id] = item.updated }
            for id in removed { indexed[id] = nil }
            saveIndexed()
        } catch {
            print("Nog: Spotlight indexing failed: \(error)")
        }
    }

    private static func loadIndexed() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        var result: [UUID: Date] = [:]
        for (key, seconds) in stored {
            if let id = UUID(uuidString: key) { result[id] = Date(timeIntervalSinceReferenceDate: seconds) }
        }
        return result
    }

    private static func saveIndexed() {
        var stored: [String: Double] = [:]
        for (id, date) in indexed { stored[id.uuidString] = date.timeIntervalSinceReferenceDate }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
