import ActivityKit
import AlarmKit
import AppIntents
import Foundation
import SwiftUI
import UIKit

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

    /// Conservative app budget, not an Apple-documented system limit.
    /// Scheduling can still fail below this; keep notification fallback intact.
    nonisolated static let alarmCap = 60

    private let manager: any NogAlarmManaging
    private let defaults: UserDefaults
    private static let recordsKey = "nog.alarmRecords.v1"
    private var records: [String: NogAlarmRecord]
    private var running: Task<[UUID: [Date]], Never>?
    private(set) var deferredAlarmCount = 0

    init(manager: (any NogAlarmManaging)? = nil, defaults: UserDefaults = .standard) {
        self.manager = manager ?? SystemNogAlarmManager()
        self.defaults = defaults
        self.records = defaults.data(forKey: Self.recordsKey)
            .flatMap { try? JSONDecoder().decode([String: NogAlarmRecord].self, from: $0) } ?? [:]
    }

    private func persistRecords() {
        do { defaults.set(try JSONEncoder().encode(records), forKey: Self.recordsKey) }
        catch { print("Nog: couldn't encode alarm ownership: \(error)") }
    }

    var authorizationState: AlarmManager.AuthorizationState { manager.authorizationState }

    var isAuthorized: Bool { manager.authorizationState == .authorized }

    @discardableResult
    func requestAuthorization() async -> Bool {
        switch manager.authorizationState {
        case .authorized: return true
        case .denied: return false
        case .notDetermined: return (try? await manager.requestAuthorization()) == .authorized
        @unknown default: return false
        }
    }

    /// Brings scheduled alarms in line with the items.
    /// Returns, per item, the times that will ring as alarms (notifications skip those).
    func sync(items: [Item], policy: NogPolicy, shortParents: [String: String] = [:],
              now: Date = .now) async -> [UUID: [Date]] {
        // @MainActor alone does not prevent reentrancy at manager.schedule's await.
        let previous = running
        let task = Task {
            _ = await previous?.value
            return await self.performSync(items: items, policy: policy, shortParents: shortParents, now: now)
        }
        running = task
        return await task.value
    }

    private func performSync(items: [Item], policy: NogPolicy, shortParents: [String: String],
                             now: Date) async -> [UUID: [Date]] {
        deferredAlarmCount = 0
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
        // The sound is part of each alarm's ID, so changing Settings › Alarm sound replaces them.
        let sound = NotificationChime.alarm
        // A nog whose sub-nog is being worked on doesn't ring either.
        let paused = NogPlanner.pausedAncestors(in: items)
        for item in items where !paused.contains(item.id) {
            let dates = Self.alarmDates(for: item, policy: policy, now: now)
            let title = PresentationPrivacy.title(titles[item.id] ?? item.title, visible: NogSettings.showTitles)
            for date in dates {
                desired[Self.alarmID(item: item, title: title + "|" + sound.rawValue, date: date)] = (item, title, date)
            }
        }
        // Read failures are not an empty AlarmKit store. Don't schedule duplicates
        // or erase our ownership journal; allow normal notifications as fallback.
        let existing: [NogAlarmSnapshot]
        do { existing = try manager.alarms() }
        catch {
            deferredAlarmCount = desired.count
            print("Nog: couldn't read alarms; keeping notification fallback: \(error)")
            return [:]
        }
        var liveIDs = Set(existing.map(\.id))
        records = records.filter { UUID(uuidString: $0.key).map(liveIDs.contains) ?? false }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let protectedIDs = Set(existing.filter { alarm in
            guard alarm.state == .alerting else { return false }
            // Explicit global silence applies even to legacy alarms without a journal.
            guard !policy.isSilenced(at: now), !policy.quiet.contains(now) else { return false }
            // Upgrade from a version without a journal: don't silence an unknown
            // active ring. It still occupies a slot until stopped by the user.
            guard let record = records[alarm.id.uuidString] else { return true }
            guard let item = byID[record.itemID], !paused.contains(item.id) else { return false }
            return Self.shouldKeepAlerting(item: item, policy: policy, now: now)
        }.map(\.id))
        // Deterministic tie-breaking avoids churn when several nogs share a date.
        let ordered = desired.sorted {
            $0.value.date != $1.value.date ? $0.value.date < $1.value.date
                : $0.key.uuidString < $1.key.uuidString
        }
        let protectedOutsidePlan = protectedIDs.subtracting(desired.keys).count
        let wantedIDs = Set(ordered.prefix(max(0, Self.alarmCap - protectedOutsidePlan)).map(\.key))

        // Cancel obsolete alarms before allocating slots. This includes an active
        // ring for a completed, deleted, paused or snoozed item we can identify.
        for alarm in existing where !wantedIDs.contains(alarm.id) && !protectedIDs.contains(alarm.id) {
            do {
                try manager.cancel(id: alarm.id)
                liveIDs.remove(alarm.id)
                records.removeValue(forKey: alarm.id.uuidString)
            } catch {
                // A failed cancellation still consumes budget.
                print("Nog: couldn't cancel alarm \(alarm.id): \(error)")
            }
        }
        persistRecords()

        var ringing: [UUID: [Date]] = [:]
        for (id, entry) in ordered {
            if liveIDs.contains(id) {
                // Existing alarms count even if a cancellation failed.
                records[id.uuidString] = NogAlarmRecord(itemID: entry.item.id, date: entry.date)
                ringing[entry.item.id, default: []].append(entry.date)
                continue
            }
            guard wantedIDs.contains(id), liveIDs.count < Self.alarmCap else {
                deferredAlarmCount += 1
                continue
            }
            // Record ownership before awaiting the daemon, rather than relying on
            // a later bulk save. AlarmKit remains authoritative on relaunch.
            records[id.uuidString] = NogAlarmRecord(itemID: entry.item.id, date: entry.date)
            persistRecords()
            do {
                try await manager.schedule(id: id, configuration: configuration(for: entry.item, title: entry.title, at: entry.date))
                liveIDs.insert(id)
                // Only successful or already-present alarms suppress notifications.
                ringing[entry.item.id, default: []].append(entry.date)
            } catch {
                records.removeValue(forKey: id.uuidString)
                deferredAlarmCount += 1
                print("Nog: couldn't schedule alarm \(id); using notification fallback: \(error)")
            }
        }
        persistRecords()
        return ringing
    }

    nonisolated static func shouldKeepAlerting(item: Item, policy: NogPolicy, now: Date) -> Bool {
        guard let reminder = item.effectiveReminder(policy: policy), reminder.start <= now,
              !policy.quiet.contains(now), !policy.isSilenced(at: now) else { return false }
        if reminder.alarm { return true }
        guard item.isOpen,
              let escalation = reminder.escalationDate(afterIgnored: reminder.escalateAfter ?? policy.escalateAfter)
        else { return false }
        return escalation <= now
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
            secondaryIntent: CompleteItemIntent(itemID: item.id.uuidString),
            sound: Self.alertSound(NotificationChime.alarm))
    }

    /// Settings › Alarm sound: Heyhey unless changed. iOS repeats it while the alarm rings.
    nonisolated static func alertSound(_ chime: NotificationChime) -> AlertConfiguration.AlertSound {
        guard let file = chime.fileName else { return .default }
        return .named(file)
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
