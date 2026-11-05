import AlarmKit
import AppIntents
import Foundation
import SwiftUI

/// Data AlarmKit hands back to us with each alarm.
struct NogAlarmMetadata: AlarmMetadata {
    var itemID: UUID
}

/// "Ring like an alarm": for items that must not be missed, Nog schedules
/// real AlarmKit alarms. They break through Silent mode and Focus, take over
/// the Lock Screen, show on a paired Apple Watch, and offer Done / Snooze.
///
/// Regular nog notifications keep running after the last scheduled alarm as
/// a safety net. Every Done/Snooze tap wakes the app, which tops alarms up again.
@MainActor
final class AlarmScheduler {
    static let shared = AlarmScheduler()

    /// Upcoming alarms kept scheduled per item.
    static let alarmsPerItem = 5

    private let manager = AlarmManager.shared

    var isAuthorized: Bool { manager.authorizationState == .authorized }

    @discardableResult
    func requestAuthorization() async -> Bool {
        switch manager.authorizationState {
        case .authorized: return true
        case .denied: return false
        default: return (try? await manager.requestAuthorization()) == .authorized
        }
    }

    /// Brings scheduled alarms in line with the items.
    /// Returns, per item, the moment its alarms run out (notifications take over after that).
    func sync(items: [Item]) async -> [UUID: Date] {
        guard isAuthorized else { return [:] }
        let now = Date.now

        var desired: [UUID: (item: Item, date: Date)] = [:]
        var coveredUntil: [UUID: Date] = [:]
        for item in items where item.isOpen {
            guard let reminder = item.reminder, reminder.alarm else { continue }
            let dates = reminder.fireDates(after: now, limit: Self.alarmsPerItem)
            for date in dates {
                desired[Self.alarmID(item: item, date: date)] = (item, date)
            }
            if let last = dates.last { coveredUntil[item.id] = last }
        }

        let existing = (try? manager.alarms) ?? []
        for alarm in existing where desired[alarm.id] == nil && alarm.state != .alerting {
            try? manager.cancel(id: alarm.id)
        }
        let existingIDs = Set(existing.map(\.id))
        for (id, entry) in desired where !existingIDs.contains(id) {
            do {
                _ = try await manager.schedule(id: id, configuration: configuration(for: entry.item, at: entry.date))
            } catch {
                print("Nog: couldn't schedule alarm for \(entry.item.title): \(error)")
            }
        }
        return coveredUntil
    }

    private func configuration(for item: Item, at date: Date) -> AlarmManager.AlarmConfiguration<NogAlarmMetadata> {
        let alert = AlarmPresentation.Alert(
            title: "\(item.title)",
            stopButton: AlarmButton(text: "Done", textColor: .white, systemImageName: "checkmark"),
            secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
            secondaryButtonBehavior: .custom)
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: NogAlarmMetadata(itemID: item.id),
            tintColor: Color.orange)
        return .alarm(
            schedule: .fixed(date),
            attributes: attributes,
            // iOS 27: lets people say "Siri, snooze it" while it rings.
            appEntityIdentifier: EntityIdentifier(for: ReminderEntity.self, identifier: item.id),
            stopIntent: CompleteItemIntent(itemID: item.id.uuidString),
            secondaryIntent: SnoozeItemIntent(itemID: item.id.uuidString))
    }

    /// Stable per (item, time, title), so unchanged alarms are left alone.
    static func alarmID(item: Item, date: Date) -> UUID {
        var bytes = item.id.uuid
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(Int(date.timeIntervalSince1970))|\(item.title)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<8 { raw[8 + i] ^= UInt8(truncatingIfNeeded: hash >> (8 * UInt64(i))) }
        }
        return UUID(uuid: bytes)
    }
}

// MARK: - Button intents (also used by alarms; hidden from Shortcuts)

struct CompleteItemIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark Nog Item Done"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Item ID")
    var itemID: String

    init() {}
    init(itemID: String) { self.itemID = itemID }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: itemID) {
            ItemStore.shared.markDone(id)
            await ItemStore.shared.syncNow()
            await ItemStore.shared.flush()
        }
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

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: itemID), let item = ItemStore.shared.items[id] {
            // Snooze by the item's own gap (at least 5 minutes).
            let gap = max(300, item.reminder?.gap(after: 0) ?? 600)
            ItemStore.shared.snooze(id, until: .now.addingTimeInterval(gap))
            await ItemStore.shared.syncNow()
            await ItemStore.shared.flush()
        }
        return .result()
    }
}
