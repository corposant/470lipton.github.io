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
    var category: String = NogPlanner.categoryNog
    /// A "coming up" note before the nogs start, not a nog itself.
    var isHeadsUp = false
    /// Hush: no sound, and no Time Sensitive break-through.
    var silent = false

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
    static let categoryNog = "NOG"
    static let categoryDoing = "NOG_DOING"
    /// "Open Nog to keep nogging": no buttons, and nothing about the item in it.
    static let categoryPause = "NOG_PAUSE"
    static let defaultBudget = 60

    /// The notification category for an item's nogs: "NOG", or e.g. "NOG_S30_M510" when it has
    /// its own snooze length / morning time, so its notification buttons say the right thing.
    static func category(for reminder: Reminder?) -> String {
        var id = categoryNog
        if let s = reminder?.snoozeMinutes { id += "_S\(s)" }
        if let m = reminder?.morningMinutes { id += "_M\(m)" }
        return id
    }

    /// Reads a category back: (snooze minutes, morning minutes), nil where it uses the defaults.
    static func snoozeSettings(fromCategory id: String) -> (snooze: Int?, morning: Int?) {
        var snooze: Int?, morning: Int?
        for part in id.split(separator: "_").dropFirst() {
            if part.hasPrefix("S") { snooze = Int(part.dropFirst()) }
            if part.hasPrefix("M") { morning = Int(part.dropFirst()) }
        }
        return (snooze, morning)
    }

    static func plan(items: [Item], now: Date,
                     budget: Int = defaultBudget,
                     maxFollowUpsPerItem: Int = 24,
                     policy: NogPolicy = .standard,
                     alarmDates: [UUID: [Date]] = [:],
                     calendar: Calendar = .current) -> [PlannedNotification] {
        // Silenced until turned back on: nothing at all.
        if policy.isSilencedIndefinitely(at: now) { return [] }
        let candidates: [(Item, Reminder)] = items
            .compactMap { item -> (Item, Reminder)? in
                guard let r = item.effectiveReminder(policy: policy) else { return nil }
                return (item, r)
            }
            .sorted { a, b in
                a.1.start != b.1.start ? a.1.start < b.1.start : a.0.id.uuidString < b.0.id.uuidString
            }

        var primaries: [PlannedNotification] = []
        var followUps: [PlannedNotification] = []

        for (item, r) in candidates {
            let doing = item.isDoing
            let body = doing
                ? (item.timeboxMinutes != nil ? "Time's up. Done, or 10 more minutes?" : "Still on it?")
                : (r.repeatSummary.map { "Nogging \($0) until done" } ?? "Reminder")
            let category = doing ? categoryDoing : self.category(for: item.reminder)
            // A change of category (its buttons) must replace already-scheduled nogs.
            // So does turning Hush on or off (the sound is baked into each request).
            let titleTag = stableHash((category == categoryNog || doing ? item.title : item.title + "|" + category)
                                      + (r.silent ? "|silent" : ""))
            let base = "\(prefix)\(item.id.uuidString)\(doing ? ".doing" : "")"

            func oneShot(_ date: Date, body: String = body, kind: String = "at") -> PlannedNotification {
                PlannedNotification(identifier: "\(base).\(kind).\(Int(date.timeIntervalSince1970)).\(titleTag)",
                                    itemID: item.id, title: item.title, body: body, trigger: .at(date),
                                    category: category, isHeadsUp: kind == "heads", silent: r.silent)
            }

            // Heads-up before a dated nog starts: the global one, plus Building's 15 / 5 / 1 min
            // countdown, which eases the switch into a task.
            if !doing {
                var leads = policy.headsUpMinutes > 0 ? [policy.headsUpMinutes] : []
                if r.curve == .building { leads += Reminder.buildingHeadsUpMinutes }
                for lead in Set(leads).sorted(by: >) {
                    let headsUp = r.start.addingTimeInterval(TimeInterval(-lead * 60))
                    if headsUp > now, !policy.quiet.contains(headsUp, calendar: calendar), !policy.isSilenced(at: headsUp) {
                        followUps.append(oneShot(headsUp, body: "Coming up in \(IntervalFormat.amount(lead))", kind: "heads"))
                    }
                }
            }

            let ringing = Set(alarmDates[item.id] ?? [])
            let needsExactTimes = policy.quiet.enabled || !ringing.isEmpty || policy.isSilenced(at: now)

            if !needsExactTimes, let settled = r.settledPhase, settled.since <= now {
                // Gap no longer changes: one trigger iOS repeats forever.
                let seconds = max(60, settled.gap)
                primaries.append(PlannedNotification(
                    identifier: "\(base).every.\(Int(seconds)).\(Int(settled.since.timeIntervalSince1970)).\(titleTag)",
                    itemID: item.id, title: item.title, body: body, trigger: .every(seconds),
                    category: category, silent: r.silent))
            } else {
                // Exact times: skip the ones an alarm already covers, push quiet-hour ones to when quiet ends.
                var dates: [Date] = []
                var seen = Set<Date>()
                for date in r.fireDates(after: now, limit: 1 + max(0, maxFollowUpsPerItem) + ringing.count) {
                    guard !ringing.contains(date) else { continue }
                    guard let when = policy.nextAllowed(after: date, calendar: calendar) else { break }
                    if seen.insert(when).inserted { dates.append(when) }
                    if dates.count > maxFollowUpsPerItem { break }
                }
                guard let first = dates.first else { continue } // one-shot already fired
                primaries.append(oneShot(first))
                followUps.append(contentsOf: dates.dropFirst().map { oneShot($0) })
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

    /// One-shot nogs run out: iOS keeps at most 64 pending, so an item on exact times (quiet hours,
    /// a timed silence, alarms, or a start still to come) only has its next few hours lined up, and
    /// only the app can line up more. If the app isn't opened or woken by then, the nogs would stop
    /// without a word. This is a last notification, just after the earliest point where an item that
    /// should keep nogging has nothing more scheduled, asking you to open Nog so they carry on.
    /// nil when nothing runs out (every repeating item has a forever-repeating trigger).
    static func pauseNotice(for plan: [PlannedNotification], items: [Item], now: Date,
                            policy: NogPolicy = .standard, calendar: Calendar = .current) -> PlannedNotification? {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var lastByItem: [UUID: Date] = [:]
        var repeatingForever = Set<UUID>()
        for p in plan where !p.isHeadsUp {
            switch p.trigger {
            case .every: repeatingForever.insert(p.itemID)
            case .at(let date): lastByItem[p.itemID] = max(lastByItem[p.itemID] ?? date, date)
            }
        }
        // Items that would keep nogging after their last scheduled one-shot.
        let runsOut = lastByItem.filter { id, _ in
            !repeatingForever.contains(id) && byID[id]?.effectiveReminder(policy: policy)?.repeatMinutes != nil
        }
        guard let earliest = runsOut.min(by: { $0.value < $1.value }),
              let when = policy.nextAllowed(after: earliest.value.addingTimeInterval(60), calendar: calendar),
              when > now else { return nil }
        return PlannedNotification(
            identifier: "\(prefix)pause.\(Int(when.timeIntervalSince1970))",
            itemID: earliest.key,
            title: "Open Nog to keep nogging",
            body: "Nog has run out of nogs lined up ahead. Open the app and they'll carry on.",
            trigger: .at(when),
            category: categoryPause)
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
