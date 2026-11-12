import Foundation

/// A notification we want iOS to have scheduled.
struct PlannedNotification: Hashable {
    enum Trigger: Hashable {
        /// Fire once at this moment.
        case at(Date)
        /// Fire every N seconds, forever, until removed (iOS minimum is 60s).
        case every(TimeInterval)
        /// Fire every day at this time of day, forever, until removed. Unlike `.every(86_400)`,
        /// which counts from whenever it was scheduled, this keeps "same time each day".
        case daily(hour: Int, minute: Int)
        /// Fire when you arrive at (or leave) a saved place.
        case place(latitude: Double, longitude: Double, radius: Double, leaving: Bool)
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
    /// The end of the two-minute start: plays Nog's soft chime instead of the usual sound,
    /// and never breaks through as Time Sensitive.
    var chime = false

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
    /// "Coming up in 5 min": Start now / Push 15 min / Done.
    static let categoryHeadsUp = "NOG_HEADS"
    static let defaultBudget = 60

    /// While counting up past the starter timer (or open-ended).
    static let checkInBody = "Still on it? Your time is being logged."

    /// When the starter timer runs out: permission to stop, and an open door to keep going.
    static func starterDoneBody(minutes: Int) -> String {
        "\(minutes == 2 ? "Two minutes" : IntervalFormat.amount(minutes)) done. Keep going, or stop here. Both count."
    }

    /// The notification category for an item's nogs: "NOG", or e.g. "NOG_S30_M510_G" when it has
    /// its own snooze length / morning time, or a profile with its own buttons, so its notification
    /// buttons say the right thing. "_G": the profile has a Gentler step. "_K": Skip today, not
    /// Snooze till morning (Daily, Teatime).
    static func category(for reminder: Reminder?) -> String {
        var id = categoryNog
        if let s = reminder?.snoozeMinutes { id += "_S\(s)" }
        if let m = reminder?.morningMinutes { id += "_M\(m)" }
        if let profile = reminder.flatMap(NogProfile.matching) {
            if profile.gentler != nil { id += "_G" }
            if profile.skipsDays { id += "_K" }
        }
        return id
    }

    /// Reads a category's profile buttons back.
    static func profileButtons(fromCategory id: String) -> (gentler: Bool, skipToday: Bool) {
        let parts = id.split(separator: "_").dropFirst()
        return (parts.contains("G"), parts.contains("K"))
    }

    /// The line under a nog's title: its profile's voice, or the plain rhythm for a custom one.
    static func bannerLine(for r: Reminder) -> String {
        guard r.repeatMinutes != nil else { return "Reminder" }
        if let profile = NogProfile.matching(r) { return profile.bannerLine }
        return r.repeatSummary.map { "Nogging \($0) until done" } ?? "Reminder"
    }

    /// "Alarm next." / "Alarm after 2 more." for a nog with an alarm coming (ignored nogs escalate).
    static func alarmCountdown(nogsBeforeAlarm n: Int) -> String {
        n == 0 ? "Alarm next." : "Alarm after \(n) more."
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
            let body = doing ? checkInBody : bannerLine(for: r)
            let category = doing ? categoryDoing : self.category(for: item.reminder)
            // A change of category (its buttons) must replace already-scheduled nogs.
            // So does turning Hush on or off (the sound is baked into each request), or a new banner line.
            let titleTag = stableHash((category == categoryNog || doing ? item.title : item.title + "|" + category)
                                      + (r.silent ? "|silent" : "") + "|" + body)
            let base = "\(prefix)\(item.id.uuidString)\(doing ? ".doing" : "")"

            func oneShot(_ date: Date, body: String = body, kind: String = "at") -> PlannedNotification {
                PlannedNotification(identifier: "\(base).\(kind).\(Int(date.timeIntervalSince1970)).\(titleTag)",
                                    itemID: item.id, title: item.title, body: body, trigger: .at(date),
                                    category: kind == "heads" ? categoryHeadsUp : category,
                                    isHeadsUp: kind == "heads", silent: r.silent, chime: kind == "chime")
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

            // Gap no longer changes: one trigger iOS repeats forever. A day-long gap uses a daily
            // calendar trigger so it stays at the item's time of day (a time-interval trigger
            // counts from when it was scheduled, so it would drift to whenever the app last ran).
            // Gaps over a day (Teatime's every other day) have no repeating trigger that keeps
            // their time, so they use exact one-shots below.
            var settled: (since: Date, gap: TimeInterval)?
            if !needsExactTimes, let phase = r.settledPhase, phase.since <= now, phase.gap <= 86_400 { settled = phase }
            if let settled, settled.gap == 86_400, let next = r.nextFire(after: now) {
                let time = calendar.dateComponents([.hour, .minute], from: next)
                let hour = time.hour ?? 9, minute = time.minute ?? 0
                primaries.append(PlannedNotification(
                    identifier: "\(base).daily.\(hour).\(minute).\(titleTag)",
                    itemID: item.id, title: item.title, body: body, trigger: .daily(hour: hour, minute: minute),
                    category: category, silent: r.silent))
            } else if let settled {
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
                guard !dates.isEmpty else { continue } // one-shot already fired
                // With an alarm coming, each nog before it says how many are left.
                let alarms = ringing.sorted()
                let nogs = dates.map { date -> PlannedNotification in
                    // The starter timer running out: the soft chime, not a nag.
                    if doing, date == item.timeboxEnd, let minutes = item.timeboxMinutes {
                        return oneShot(date, body: starterDoneBody(minutes: minutes), kind: "chime")
                    }
                    guard !doing, let alarm = alarms.first(where: { $0 > date }) else { return oneShot(date) }
                    let left = dates.filter { $0 > date && $0 < alarm }.count
                    return oneShot(date, body: alarmCountdown(nogsBeforeAlarm: left), kind: "at\(left)")
                }
                primaries.append(nogs[0])
                followUps.append(contentsOf: nogs.dropFirst())
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
            case .every, .daily: repeatingForever.insert(p.itemID)
            case .at(let date): lastByItem[p.itemID] = max(lastByItem[p.itemID] ?? date, date)
            case .place: break
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
            body: "Reminders pause until you do.",
            trigger: .at(when),
            category: categoryPause)
    }

    /// FNV-1a — stable across launches (unlike Swift's hashValue).
    /// "When I get home" items: one notification each, fired by iOS when you arrive (or leave).
    /// Unknown places (not saved yet) are skipped. iOS watches at most 20 regions per app.
    static let placePrefix = prefix + "place."

    static func placeNotifications(items: [Item], places: [SavedPlace], limit: Int) -> [PlannedNotification] {
        let byName = Dictionary(places.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        return items
            .filter { $0.isOpen && $0.place != nil }
            .sorted { $0.created < $1.created }
            .compactMap { item -> PlannedNotification? in
                guard let trigger = item.place, let place = byName[trigger.name.lowercased()] else { return nil }
                let key = String(format: "%.5f,%.5f,%.0f,%@", place.latitude, place.longitude, place.radius,
                                 trigger.leaving ? "x" : "e")
                return PlannedNotification(
                    identifier: "\(placePrefix)\(item.id.uuidString).\(stableHash(key + "|" + item.title))",
                    itemID: item.id, title: item.title,
                    body: trigger.leaving ? "You're leaving \(place.name)." : "You're at \(place.name).",
                    trigger: .place(latitude: place.latitude, longitude: place.longitude,
                                    radius: place.radius, leaving: trigger.leaving),
                    category: category(for: item.reminder))
            }
            .prefix(limit)
            .map { $0 }
    }

    static func stableHash(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return String(h, radix: 16)
    }
}

/// What you typed into a notification's "Later…" box: a time ("20m", "4pm", "tomorrow", "in an hour")
/// and/or a profile ("!hush", "!tea"). A bare number is minutes.
struct LaterReply: Equatable {
    var start: Date?
    var profile: NogProfile?

    static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> LaterReply {
        var reply = LaterReply()
        var words: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let profile = NogProfile.token(word) { reply.profile = profile } else { words.append(word) }
        }
        let rest = words.joined(separator: " ")
        guard !rest.isEmpty else { return reply }
        if let n = Int(rest), n > 0, n <= 10_000 {
            reply.start = now.addingTimeInterval(TimeInterval(n * 60))
            return reply
        }
        // "4pm" and "tomorrow" read as they are; "20m" and "an hour" need an "in".
        for phrase in [rest, "in " + rest] {
            if let start = NaturalDateParser.parse(phrase, now: now, calendar: calendar).start, start > now {
                reply.start = start
                return reply
            }
        }
        return reply
    }
}
