import Foundation

/// What the Home Screen and Lock Screen widgets know about your nogs.
///
/// The widget extension can't open the app's item files (they live in the app's own
/// container or iCloud Drive), so the app writes this small JSON summary into the
/// shared App Group container every time items change, then asks WidgetKit to reload.
/// Compiled into both the app and the NogWidgets extension.
struct WidgetSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id: UUID
        var title: String
        /// "open", "doing" or "someday" (finished items aren't included).
        var status: String
        var tags: [String]
        var parentTitle: String?
        /// When it starts nogging; nil = a loose nog (no reminder).
        var start: Date?
        /// The next nog after the snapshot was taken (quiet hours applied), if any.
        var nextNog: Date?
        /// Rings as an alarm.
        var alarm: Bool
        /// The timebox ▶︎ would use right now; nil = open-ended.
        var suggestedMinutes: Int?
        /// While doing: when this session started, and its timebox.
        var doingSince: Date?
        var timeboxMinutes: Int?
        /// Sub-items (open first), for the large timer widget and the progress ring.
        var subItems: [SubItem]
        var subDone: Int
        var subTotal: Int
        var updated: Date

        var isOpen: Bool { status == "open" }
        var isDoing: Bool { status == "doing" }
        var isDream: Bool { status == "someday" }

        var timeboxEnd: Date? {
            guard isDoing, let since = doingSince, let box = timeboxMinutes else { return nil }
            return since.addingTimeInterval(TimeInterval(box * 60))
        }

        /// Nogging (its start has passed) at `date`.
        func isNogging(at date: Date) -> Bool {
            guard isOpen, let start else { return false }
            return start <= date
        }

        /// When it next nogs as seen from `date`: the snapshot's next nog, or its start.
        func when(at date: Date) -> Date? {
            if let nextNog, nextNog > date { return nextNog }
            return start
        }
    }

    struct SubItem: Codable, Equatable {
        var title: String
        var done: Bool
    }

    var generated: Date
    var entries: [Entry]
    /// Settings → "Show titles on Lock Screen".
    var showTitlesOnLockScreen: Bool
    /// Settings › Theme: "dark" or "light", or nil to follow the system (also older snapshots).
    var appearance: String? = nil
    /// Settings › Low stimulation: the widgets drop their haze, honeycomb and glow too.
    /// nil in older snapshots, which reads as off.
    var lowStimulation: Bool? = nil

    static let empty = WidgetSnapshot(generated: .distantPast, entries: [], showTitlesOnLockScreen: true)

    /// What you're doing now: the most recently started item.
    var doing: Entry? {
        entries.filter(\.isDoing).max { ($0.doingSince ?? .distantPast) < ($1.doingSince ?? .distantPast) }
    }

    /// Open and doing items: the ones a widget can start or finish.
    var outstanding: [Entry] {
        entries.filter { $0.isOpen || $0.isDoing }
    }
}

/// The App Group container the app and the widgets share.
enum WidgetStore {
    /// `NogAppGroup` in Info.plist, set from the bundle ID in project.yml.
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "NogAppGroup") as? String
    }

    static var fileURL: URL? {
        guard let groupID,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return nil }
        return container.appending(path: "widget-snapshot.json")
    }

    static func encode(_ snapshot: WidgetSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(snapshot)
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// nil when there's no App Group yet (the app hasn't run since installing the widgets).
    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}
