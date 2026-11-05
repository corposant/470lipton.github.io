import Foundation

/// A notification we want iOS to have scheduled.
struct PlannedNotification: Hashable {
    enum Trigger: Hashable {
        /// Fire once at this moment.
        case at(Date)
        /// Fire every N seconds, forever, until removed (iOS minimum is 60s).
        case every(TimeInterval)
    }

    /// Encodes everything that matters about the request, so an unchanged
    /// request keeps its identifier and is left alone (keeping its timing).
    var identifier: String
    var itemID: UUID
    var title: String
    var body: String
    var trigger: Trigger

    var fireDate: Date? {
        if case .at(let date) = trigger { return date }
        return nil
    }
}

/// Decides which notifications should be pending, within iOS's limit of
/// 64 pending notifications per app.
///
/// - An item that is already nogging at a fixed gap gets ONE repeating trigger
///   that keeps firing forever, even if the app never runs again.
/// - A logarithmic item that's still easing off gets exact one-shots for its
///   growing gaps; once the gap reaches a day it switches to the repeating trigger.
/// - An item whose nog starts in the future gets a one-shot at the start time,
///   plus follow-ups at start + N, start + 2N… while there's room. Whenever the
///   app wakes up (opened, notification action, background refresh), the plan
///   is recomputed and started items switch over to the repeating trigger.
enum NogPlanner {
    static let prefix = "nog."
    static let defaultBudget = 60

    static func plan(items: [Item], now: Date,
                     budget: Int = defaultBudget,
                     maxFollowUpsPerItem: Int = 24) -> [PlannedNotification] {
        let candidates: [(Item, Reminder)] = items
            .compactMap { item -> (Item, Reminder)? in
                guard item.isOpen, let r = item.reminder else { return nil }
                return (item, r)
            }
            .sorted { a, b in
                a.1.start != b.1.start ? a.1.start < b.1.start : a.0.id.uuidString < b.0.id.uuidString
            }

        var primaries: [PlannedNotification] = []
        var followUps: [PlannedNotification] = []

        for (item, r) in candidates {
            let body = r.repeatSummary.map { "Nogging \($0) until done" } ?? "Reminder"
            let titleTag = stableHash(item.title)
            let base = "\(prefix)\(item.id.uuidString)"

            func oneShot(_ date: Date) -> PlannedNotification {
                PlannedNotification(identifier: "\(base).at.\(Int(date.timeIntervalSince1970)).\(titleTag)",
                                    itemID: item.id, title: item.title, body: body, trigger: .at(date))
            }

            if let settled = r.settledPhase, settled.since <= now {
                // Gap no longer changes: one trigger iOS repeats forever.
                let seconds = max(60, settled.gap)
                primaries.append(PlannedNotification(
                    identifier: "\(base).every.\(Int(seconds)).\(Int(settled.since.timeIntervalSince1970)).\(titleTag)",
                    itemID: item.id, title: item.title, body: body, trigger: .every(seconds)))
            } else {
                // Still ahead of us (or easing off): exact times, re-planned whenever the app wakes.
                let dates = r.fireDates(after: now, limit: 1 + max(0, maxFollowUpsPerItem))
                guard let first = dates.first else { continue } // one-shot already fired
                primaries.append(oneShot(first))
                followUps.append(contentsOf: dates.dropFirst().map(oneShot))
            }
        }

        let kept = Array(primaries.prefix(max(0, budget)))
        let remaining = budget - kept.count
        guard remaining > 0 else { return kept }
        let keptItems = Set(kept.map(\.itemID))
        let extra = followUps
            .filter { keptItems.contains($0.itemID) }
            .sorted { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }
            .prefix(remaining)
        return kept + extra
    }

    /// FNV-1a — stable across launches (unlike Swift's hashValue).
    static func stableHash(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return String(h, radix: 16)
    }
}
