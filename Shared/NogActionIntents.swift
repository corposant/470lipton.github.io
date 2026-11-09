import AppIntents
import Foundation

// Buttons on alarms, Live Activities and notifications.
// These are LiveActivityIntents, so the system runs them in the app process
// even when tapped from the Lock Screen. The widget extension compiles the
// same types (so its buttons can reference them) without the app's store.

struct CompleteItemIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark Nog Item Done"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Item ID")
    var itemID: String

    init() {}
    init(itemID: String) { self.itemID = itemID }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await NogActions.run(itemID) { store, id in store.markDone(id) }
        #endif
        return .result()
    }
}

struct SnoozeItemIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Snooze Nog Item"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Item ID")
    var itemID: String

    init() {}
    init(itemID: String) { self.itemID = itemID }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await NogActions.run(itemID) { store, id in
            // Snooze by the item's own gap (at least 5 minutes).
            let gap = max(300, store.items[id]?.reminder?.gap(after: 0) ?? 600)
            store.snooze(id, until: .now.addingTimeInterval(gap))
        }
        #endif
        return .result()
    }
}

struct ExtendTimeboxIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Add Time"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Item ID")
    var itemID: String

    @Parameter(title: "Minutes", default: 10)
    var minutes: Int

    init() {}
    init(itemID: String, minutes: Int) {
        self.itemID = itemID
        self.minutes = minutes
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let minutes = minutes
        await NogActions.run(itemID) { store, id in store.extend(id, minutes: minutes) }
        #endif
        return .result()
    }
}

struct StopDoingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Working"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Item ID")
    var itemID: String

    init() {}
    init(itemID: String) { self.itemID = itemID }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await NogActions.run(itemID) { store, id in store.stopDoing(id) }
        #endif
        return .result()
    }
}

/// ▶︎ on a widget: start doing an item with Nog's suggested timebox, which starts its Live Activity.
struct StartDoingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Nog Item"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Item ID")
    var itemID: String

    init() {}
    init(itemID: String) { self.itemID = itemID }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await NogActions.run(itemID) { store, id in store.start(id) }
        #endif
        return .result()
    }
}

#if !WIDGET_EXTENSION
enum NogActions {
    @MainActor
    static func run(_ itemID: String, _ action: @MainActor (ItemStore, UUID) -> Void) async {
        guard let id = UUID(uuidString: itemID) else { return }
        let store = ItemStore.shared
        action(store, id)
        await store.syncNow()
        await store.flush()
    }
}
#endif
