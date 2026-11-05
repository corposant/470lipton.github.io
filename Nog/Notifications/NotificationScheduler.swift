import Foundation
import UserNotifications

/// Keeps iOS's pending notifications in line with `NagPlanner`'s plan.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    nonisolated static let categoryID = "NAG"
    nonisolated static let itemIDKey = "itemID"

    enum Action: String {
        case done = "NAG_DONE"
        case snoozeHour = "NAG_SNOOZE_1H"
        case morning = "NAG_MORNING"
    }

    private let center = UNUserNotificationCenter.current()
    private var running: Task<Void, Never>?
    private(set) var lastPlannedCount = 0

    func registerCategories() {
        let done = UNNotificationAction(identifier: Action.done.rawValue, title: "Done ✓", options: [])
        let snooze = UNNotificationAction(identifier: Action.snoozeHour.rawValue, title: "Snooze 1 hour", options: [])
        let morning = UNNotificationAction(identifier: Action.morning.rawValue, title: "Tomorrow morning", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryID,
                                              actions: [done, snooze, morning],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func pendingCount() async -> Int {
        await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(NagPlanner.prefix) }.count
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
        let plan = NagPlanner.plan(items: items, now: .now)
        var desired: [String: PlannedNotification] = [:]
        for p in plan { desired[p.identifier] = p }

        let pending = await center.pendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier).filter { $0.hasPrefix(NagPlanner.prefix) })

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
        content.title = planned.title
        content.body = planned.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.threadIdentifier = planned.itemID.uuidString
        content.userInfo = [Self.itemIDKey: planned.itemID.uuidString]
        // Takes effect once the Time Sensitive capability is added (see README).
        content.interruptionLevel = .timeSensitive

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
