import AppIntents
import Foundation
import UserNotifications

/// Keeps iOS's pending notifications in line with `NogPlanner`'s plan.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    nonisolated static let categoryID = "NOG"
    nonisolated static let itemIDKey = "itemID"

    enum Action: String {
        case done = "NOG_DONE"
        case snoozeHour = "NOG_SNOOZE_1H"
        case morning = "NOG_MORNING"
        case extend = "NOG_EXTEND_10"
        case stopDoing = "NOG_STOP"
    }

    private let center = UNUserNotificationCenter.current()
    private var running: Task<Void, Never>?
    private(set) var lastPlannedCount = 0

    private var registeredCategories: Set<String> = []
    /// Custom categories seen at the last sync, kept when re-registering without items.
    private var customCategories: Set<String> = []

    /// The default nog category, the Doing one, plus one per custom snooze combination in use.
    /// Without `items` (launch, Settings changes) it keeps the custom ones from the last sync.
    func registerCategories(items: [Item]? = nil) {
        if let items { customCategories = Set(items.map { NogPlanner.category(for: $0.reminder) }) }
        let ids = customCategories.union([Self.categoryID])
        let signature = ids.union(["\(NogSettings.snoozeMinutes)|\(NogSettings.morningMinutes)"])
        guard signature != registeredCategories else { return }
        registeredCategories = signature

        let done = UNNotificationAction(identifier: Action.done.rawValue, title: "Done ✓", options: [])
        var categories: Set<UNNotificationCategory> = []
        for id in ids {
            let custom = NogPlanner.snoozeSettings(fromCategory: id)
            let snoozeMinutes = custom.snooze ?? NogSettings.snoozeMinutes
            let morningMinutes = custom.morning ?? NogSettings.morningMinutes
            let snooze = UNNotificationAction(identifier: Action.snoozeHour.rawValue,
                                              title: NogSettings.snoozeLabel(minutes: snoozeMinutes), options: [])
            let morning = UNNotificationAction(identifier: Action.morning.rawValue,
                                               title: NogSettings.morningLabel(minutes: morningMinutes), options: [])
            categories.insert(UNNotificationCategory(identifier: id, actions: [done, snooze, morning],
                                                     intentIdentifiers: [], options: []))
        }
        let doing = UNNotificationCategory(
            identifier: NogPlanner.categoryDoing,
            actions: [
                done,
                UNNotificationAction(identifier: Action.extend.rawValue, title: "+10 minutes", options: []),
                UNNotificationAction(identifier: Action.stopDoing.rawValue, title: "Stop for now", options: []),
            ],
            intentIdentifiers: [],
            options: [])
        categories.insert(doing)
        center.setNotificationCategories(categories)
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func pendingCount() async -> Int {
        await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(NogPlanner.prefix) }.count
    }

    /// Serialized: each sync waits for the previous one so they never interleave.
    func sync(items: [Item]) async {
        let previous = running
        let task = Task {
            await previous?.value
            await self.performSync(items: items)
        }
        running = task
        await task.value
    }

    private func performSync(items: [Item]) async {
        registerCategories(items: items)
        let policy = NogSettings.policy
        let ringing = await AlarmScheduler.shared.sync(items: items, policy: policy)
        let plan = NogPlanner.plan(items: items, now: .now, policy: policy, alarmDates: ringing)
        var desired: [String: PlannedNotification] = [:]
        for p in plan { desired[p.identifier] = p }

        let pending = await center.pendingNotificationRequests()
        var pendingIDs = Set(pending.map(\.identifier).filter { $0.hasPrefix(NogPlanner.prefix) })

        // Sound / Time Sensitive / title settings changed: everything already scheduled is out of date.
        let signature = Self.contentSignature
        if UserDefaults.standard.string(forKey: Self.signatureKey) != signature {
            center.removePendingNotificationRequests(withIdentifiers: Array(pendingIDs))
            pendingIDs = []
            UserDefaults.standard.set(signature, forKey: Self.signatureKey)
        }

        let stale = pendingIDs.subtracting(desired.keys)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }
        for (id, planned) in desired where !pendingIDs.contains(id) {
            do {
                try await center.add(request(for: planned))
            } catch {
                print("Nog: failed to schedule \(id): \(error)")
            }
        }
        lastPlannedCount = desired.count

        // App icon badge: how many things are nogging right now.
        let nogging = NogSettings.showsBadge
            ? items.filter { $0.isOpen && ($0.reminder?.isActive(at: .now) ?? false) }.count
            : 0
        try? await center.setBadgeCount(nogging)
    }

    private static let signatureKey = "appliedNotificationSignature"

    private static var contentSignature: String {
        "\(NogSettings.playsSound)|\(NogSettings.timeSensitive)|\(NogSettings.showTitles)"
    }

    func clearDelivered(for itemID: UUID) async {
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .filter { ($0.request.content.userInfo[Self.itemIDKey] as? String) == itemID.uuidString }
            .map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    private func request(for planned: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        if NogSettings.showTitles {
            content.title = planned.title
            content.body = planned.body
        } else {
            // Private: details only after unlocking and opening Nog.
            content.title = "Nog"
            content.body = "Something's nogging you."
        }
        content.sound = NogSettings.playsSound ? .default : nil
        content.categoryIdentifier = planned.category
        content.threadIdentifier = planned.itemID.uuidString
        content.userInfo = [Self.itemIDKey: planned.itemID.uuidString]
        // iOS 27: lets people say "Siri, mark that done" about the nog on screen.
        content.appEntityIdentifiers = [EntityIdentifier(for: ReminderEntity.self, identifier: planned.itemID)]
        // Takes effect once the Time Sensitive capability is added (see README).
        content.interruptionLevel = NogSettings.timeSensitive ? .timeSensitive : .active

        let trigger: UNNotificationTrigger
        switch planned.trigger {
        case .at(let date):
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .every(let seconds):
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, seconds), repeats: true)
        }
        return UNNotificationRequest(identifier: planned.identifier, content: content, trigger: trigger)
    }
}
