import AlarmKit
import AppIntents
import Foundation
import SwiftUI
import UIKit

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
    nonisolated static let alarmsPerItem = 5

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
    /// Returns, per item, the times that will ring as alarms (notifications skip those).
    func sync(items: [Item], policy: NogPolicy, shortParents: [String: String] = [:]) async -> [UUID: [Date]] {
        let now = Date.now
        // Something should ring (escalation turned on, Unhinged, a typed !alarm) but iOS hasn't
        // been asked yet: ask now, while you're in the app, or those alarms would never ring.
        if manager.authorizationState == .notDetermined,
           UIApplication.shared.applicationState == .active,
           items.contains(where: { !Self.alarmDates(for: $0, policy: policy, now: now, limit: 1).isEmpty }) {
            await requestAuthorization()
        }
        guard isAuthorized else { return [:] }

        // A sub-nog's alarm names its parent too: "Call back (Get the oil changed)".
        let titles = ParentContext.titles(for: items, shortened: shortParents)
        var desired: [UUID: (item: Item, title: String, date: Date)] = [:]
        var ringing: [UUID: [Date]] = [:]
        for item in items {
            let dates = Self.alarmDates(for: item, policy: policy, now: now)
            let title = titles[item.id] ?? item.title
            for date in dates {
                desired[Self.alarmID(item: item, title: title, date: date)] = (item, title, date)
            }
            if !dates.isEmpty { ringing[item.id] = dates }
        }

        let existing = (try? manager.alarms) ?? []
        for alarm in existing where desired[alarm.id] == nil && alarm.state != .alerting {
            try? manager.cancel(id: alarm.id)
        }
        let existingIDs = Set(existing.map(\.id))
        for (id, entry) in desired where !existingIDs.contains(id) {
            do {
                _ = try await manager.schedule(id: id, configuration: configuration(for: entry.item, title: entry.title, at: entry.date))
            } catch {
                print("Nog: couldn't schedule alarm for \(entry.item.title): \(error)")
            }
        }
        return ringing
    }

    /// Which upcoming nogs ring as alarms: all of them for "ring like an alarm" items
    /// (and their check-ins while you're on it), or, with escalation on, every nog after N ignored
    /// ones. The end of the two-minute start never rings: it's a soft chime.
    /// Quiet hours apply to alarms too.
    nonisolated static func alarmDates(for item: Item, policy: NogPolicy, now: Date, limit: Int = alarmsPerItem) -> [Date] {
        guard let reminder = item.effectiveReminder(policy: policy) else { return [] }
        let from: Date
        if reminder.alarm {
            from = now
        } else if item.isOpen,
                  let escalation = reminder.escalationDate(afterIgnored: reminder.escalateAfter ?? policy.escalateAfter) {
            from = max(now, escalation.addingTimeInterval(-1))
        } else {
            return []
        }
        let chime = item.isDoing ? item.timeboxEnd : nil
        return Array(reminder.fireDates(after: from, limit: limit * 3)
            .filter { $0 != chime && !policy.quiet.contains($0) && !policy.isSilenced(at: $0) }
            .prefix(limit))
    }

    private func configuration(for item: Item, title: String, at date: Date) -> AlarmManager.AlarmConfiguration<NogAlarmMetadata> {
        // Since iOS 26.1 the system supplies its own Stop button (it just silences this ring;
        // the item keeps nogging). Our one custom button finishes the item.
        let alert = AlarmPresentation.Alert(
            title: "\(title)",
            secondaryButton: AlarmButton(text: "Done", textColor: .white, systemImageName: "checkmark"),
            secondaryButtonBehavior: .custom)
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: NogAlarmMetadata(itemID: item.id),
            tintColor: Theme.pink)
        return .alarm(
            schedule: .fixed(date),
            attributes: attributes,
            // iOS 27: lets people say "Siri, snooze it" while it rings.
            appEntityIdentifier: EntityIdentifier(for: ReminderEntity.self, identifier: item.id),
            stopIntent: nil,
            secondaryIntent: CompleteItemIntent(itemID: item.id.uuidString))
    }

    /// Stable per (item, time, title), so unchanged alarms are left alone.
    nonisolated static func alarmID(item: Item, title: String, date: Date) -> UUID {
        var bytes = item.id.uuid
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(Int(date.timeIntervalSince1970))|\(title)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        withUnsafeMutableBytes(of: &bytes) { raw in
            for i in 0..<8 { raw[8 + i] ^= UInt8(truncatingIfNeeded: hash >> (8 * UInt64(i))) }
        }
        return UUID(uuid: bytes)
    }
}
