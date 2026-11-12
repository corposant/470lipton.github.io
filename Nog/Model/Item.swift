import Foundation

/// Everything is an Item: a to-do, an idea, a concept, a project.
/// An item becomes a "project" simply by having children.
struct Item: Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var body: String = ""
    var status: ItemStatus = .open
    var created: Date = .now
    var updated: Date = .now
    var completed: Date?
    var parentID: UUID?
    /// Where this sits among its siblings once they've been put in order by hand
    /// (dragged, or VoiceOver's Move up / Move down). nil = never placed: it goes
    /// after the placed ones, oldest first, so a new sub-nog lands at the bottom.
    var position: Int?
    var tags: [String] = []
    var reminder: Reminder?
    /// Comes back after it's done: every day, every Tuesday, monthly… (nil = a one-off).
    var recurrence: Recurrence?
    /// A recurring item: when it was last done, and how many times.
    var lastDone: Date?
    var timesDone: Int = 0
    /// "When I get home": reminds you at a saved place (Settings › Places).
    var place: PlaceTrigger?
    /// Recordings, oldest first (see `VoiceNote`).
    var voiceNotes: [VoiceNote] = []

    // Doing (the ▶︎ button)
    /// When the current working session started (status == .doing).
    var doingSince: Date?
    /// Length of the current session's starter timer (usually 2 min); nil = open-ended.
    /// Past its end the session keeps going and counts up.
    var timeboxMinutes: Int?
    /// This session's "still on it?" check-in gap, in minutes, chosen with a long press on the
    /// timer. nil = the Settings default; 0 = no check-ins this session.
    var checkInMinutes: Int?
    /// Total time spent in finished sessions, in seconds.
    var timeSpent: TimeInterval = 0

    var isOpen: Bool { status == .open }
    var isDoing: Bool { status == .doing }

    /// When the current timebox ends.
    var timeboxEnd: Date? {
        guard isDoing, let since = doingSince, let box = timeboxMinutes else { return nil }
        return since.addingTimeInterval(TimeInterval(box * 60))
    }

    /// Time spent including the session in progress.
    func totalTimeSpent(now: Date = .now) -> TimeInterval {
        timeSpent + (isDoing ? doingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0 : 0)
    }

    /// Has the starter timer run out, so the session is counting up?
    func isCountingUp(now: Date = .now) -> Bool {
        timeboxEnd.map { now >= $0 } ?? false
    }

    /// The "still on it?" gap for the session in progress, in minutes (nil = off).
    func checkInGap(policy: NogPolicy) -> Int? {
        if let mine = checkInMinutes { return mine > 0 ? mine : nil }
        return policy.checkInEvery
    }

    /// What should actually nog right now:
    /// - open items: their reminder
    /// - items being done: a soft chime when the starter timer (2 min) runs out, then a
    ///   "still on it?" check-in every N minutes while it counts up (open-ended: just the check-ins)
    /// - someday / done: nothing
    var effectiveReminder: Reminder? { effectiveReminder(policy: .standard) }

    func effectiveReminder(policy: NogPolicy) -> Reminder? {
        switch status {
        case .open:
            return reminder
        case .doing:
            guard let since = doingSince else { return nil }
            let checkIn = checkInGap(policy: policy).map { max(1, $0) }
            // Unhinged (ring like an alarm) items keep ringing at check-ins; the chime itself never rings.
            if let end = timeboxEnd {
                return Reminder(start: end, repeatMinutes: checkIn, alarm: reminder?.alarm ?? false,
                                silent: reminder?.silent ?? false)
            }
            guard let checkIn else { return nil }
            return Reminder(start: since.addingTimeInterval(TimeInterval(checkIn * 60)), repeatMinutes: checkIn,
                            silent: reminder?.silent ?? false)
        case .someday, .done:
            return nil
        }
    }

    /// Titles referenced with [[wiki links]] in the body.
    var outgoingLinkTitles: [String] { LinkParser.links(in: body) }
}

extension Item {
    /// Sibling order: placed ones by position, then the rest oldest first.
    static func siblingOrder(_ a: Item, _ b: Item) -> Bool {
        let pa = a.position ?? .max, pb = b.position ?? .max
        if pa != pb { return pa < pb }
        if a.created != b.created { return a.created < b.created }
        return a.id.uuidString < b.id.uuidString
    }

    /// `siblings` after moving the rows at `source` to sit before `destination`
    /// (the same meaning as SwiftUI's `onMove`).
    static func reordered(_ siblings: [Item], from source: IndexSet, to destination: Int) -> [Item] {
        let moving = source.filter { siblings.indices.contains($0) }.map { siblings[$0] }
        var rest = siblings.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = min(max(0, destination - source.filter { $0 < destination }.count), rest.count)
        rest.insert(contentsOf: moving, at: insertAt)
        return rest
    }
}

extension Item {
    /// True when something its notifications or alarms are built from differs: the title
    /// (their text and identifiers), status, reminder, or the Doing session. Notes, tags,
    /// and time spent don't change any nog.
    func changesNogs(from other: Item) -> Bool {
        title != other.title || status != other.status || reminder != other.reminder
            || recurrence != other.recurrence || place != other.place
            || doingSince != other.doingSince || timeboxMinutes != other.timeboxMinutes
            || checkInMinutes != other.checkInMinutes
    }
}

// MARK: - Tags

extension Item {
    /// "  #Big trip, " → "Big-trip": no "#", commas or edge spaces; inner spaces become dashes
    /// (a #tag is one word when typed in a capture).
    static func cleanTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#,"))
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// Adds a tag unless it's empty or already there (any capitalisation). Returns true if added.
    @discardableResult
    mutating func addTag(_ raw: String) -> Bool {
        let tag = Self.cleanTag(raw)
        guard !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return false }
        tags.append(tag)
        return true
    }

    /// Removes a tag (any capitalisation). Returns true if it was there.
    @discardableResult
    mutating func removeTag(_ tag: String) -> Bool {
        let before = tags.count
        tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        return tags.count != before
    }
}

enum ItemStatus: String, CaseIterable, Hashable {
    case open, doing, someday, done

    var label: String {
        switch self {
        case .open: "Open"
        case .doing: "Doing"
        case .someday: "Someday"
        case .done: "Done"
        }
    }

    /// Why nogs are paused, as a phrase: "Paused while you're doing it".
    var pausedReason: String {
        switch self {
        case .open: "Nogging"
        case .doing: "Paused while you're on it"
        case .someday: "Paused in Someday"
        case .done: "Off"
        }
    }
}

/// How the gap between nogs behaves.
enum RepeatCurve: String, CaseIterable, Hashable {
    /// Same gap every time: 8, 8, 8, 8…
    case steady
    /// Gap doubles each time, capped at a day: 8, 16, 32, 64… then daily, forever.
    case logarithmic
    /// Gap halves each time down to a floor, getting more insistent: 30, 15, 8, 4, 4, 4…
    case building

    var label: String {
        switch self {
        case .steady: "Steady"
        case .logarithmic: "Logarithmic"
        case .building: "Building"
        }
    }
}

/// When to start nogging, and how often to repeat until the item is done.
struct Reminder: Hashable {
    var start: Date
    /// nil = fire once. Otherwise the (first) gap between nogs, in minutes (minimum 1).
    var repeatMinutes: Int?
    var curve: RepeatCurve = .steady
    /// Ring as a real alarm (AlarmKit) that breaks through Silent and Focus.
    var alarm: Bool = false
    /// Hush: nogs arrive as a quiet banner, with no sound and no Time Sensitive break-through.
    var silent: Bool = false
    /// Ring as an alarm after this many ignored nogs. nil = the global setting, 0 = never.
    var escalateAfter: Int? = nil
    /// This item's "Snooze" length in minutes. nil = the Settings default.
    var snoozeMinutes: Int? = nil
    /// This item's "Snooze till morning" time, minutes after midnight. nil = the Settings default.
    var morningMinutes: Int? = nil
    /// A sub-item: takes its parent's rhythm (repeat, style, alarm, snooze) when that changes.
    /// Set to false once you change the sub-item's own rhythm.
    var followsParent = true
    /// A parent: its rhythm flows down to sub-items that follow it.
    var passesDown = true

    /// Logarithmic gaps stop growing here.
    static let logarithmicCapMinutes = 1440
    /// Building gaps stop shrinking here.
    static let buildingFloorMinutes = 4
    /// Building items get a heads-up this many minutes before they start, to ease the switch.
    static let buildingHeadsUpMinutes = [15, 5, 1]

    var repeatInterval: TimeInterval? {
        repeatMinutes.map { TimeInterval(max(1, $0) * 60) }
    }

    func isActive(at now: Date) -> Bool { start <= now }

    /// Gap in seconds after the k-th nog (k = 0 is the first nog).
    func gap(after k: Int) -> TimeInterval? {
        guard let base = repeatMinutes.map({ max(1, $0) }) else { return nil }
        switch curve {
        case .steady:
            return TimeInterval(base * 60)
        case .logarithmic:
            let cap = max(base, Self.logarithmicCapMinutes)
            var minutes = base
            var i = 0
            while i < k && minutes < cap {
                minutes *= 2
                i += 1
            }
            return TimeInterval(min(minutes, cap) * 60)
        case .building:
            let fastest = min(base, Self.buildingFloorMinutes)
            var minutes = base
            var i = 0
            while i < k && minutes > fastest {
                minutes = max(fastest, (minutes + 1) / 2)
                i += 1
            }
            return TimeInterval(minutes * 60)
        }
    }

    /// From this moment on the gap never changes again: (moment, gap).
    /// Lets the planner hand iOS a single forever-repeating trigger.
    var settledPhase: (since: Date, gap: TimeInterval)? {
        guard let first = gap(after: 0) else { return nil }
        var t = start
        var k = 0
        var current = first
        while let next = gap(after: k + 1), next != current, k < 64 {
            t = t.addingTimeInterval(current)
            current = next
            k += 1
        }
        return (t, current)
    }

    /// The next `limit` nog times strictly after `date`.
    func fireDates(after date: Date, limit: Int) -> [Date] {
        guard limit > 0 else { return [] }
        guard repeatMinutes != nil else { return start > date ? [start] : [] }
        var result: [Date] = []
        var t = start
        var k = 0
        while result.count < limit && k < 100_000 {
            guard let g = gap(after: k) else { break }
            // In a steady stretch that's still in the past, jump ahead instead of stepping.
            if t <= date, let next = gap(after: k + 1), next == g {
                let skip = (date.timeIntervalSince(t) / g).rounded(.down)
                if skip >= 1 {
                    t = t.addingTimeInterval(skip * g)
                    k += Int(skip)
                    continue
                }
            }
            if t > date { result.append(t) }
            t = t.addingTimeInterval(g)
            k += 1
        }
        return result
    }

    /// Best estimate of the next time this reminder fires.
    func nextFire(after now: Date) -> Date? {
        fireDates(after: now, limit: 1).first
    }

    /// "every 8 min" / "every 8 min, easing off to daily"
    var repeatSummary: String? {
        guard let m = repeatMinutes else { return nil }
        switch curve {
        case .steady: return "every \(IntervalFormat.short(m))"
        case .logarithmic: return "every \(IntervalFormat.short(m)), easing off to daily"
        case .building:
            let fastest = min(m, Self.buildingFloorMinutes)
            return "every \(IntervalFormat.short(m)), building to every \(IntervalFormat.short(fastest))"
        }
    }
}

extension Reminder {
    /// Same rhythm: everything about how it nogs except when it starts.
    func sameRhythm(as other: Reminder) -> Bool {
        repeatMinutes == other.repeatMinutes && curve == other.curve && alarm == other.alarm
            && silent == other.silent && escalateAfter == other.escalateAfter
            && snoozeMinutes == other.snoozeMinutes && morningMinutes == other.morningMinutes
    }

    /// This reminder with a parent's rhythm, keeping its own start (and its follow / pass-down switches).
    func takingRhythm(of parent: Reminder) -> Reminder {
        var r = self
        r.repeatMinutes = parent.repeatMinutes
        r.curve = parent.curve
        r.alarm = parent.alarm
        r.silent = parent.silent
        r.escalateAfter = parent.escalateAfter
        r.snoozeMinutes = parent.snoozeMinutes
        r.morningMinutes = parent.morningMinutes
        return r
    }
}

enum LinkParser {
    /// Extracts `[[Title]]` and `[[Title|alias]]` links, de-duplicated case-insensitively, in order.
    static func links(in text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var rest = text[...]
        while let open = rest.range(of: "[[") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { break }
            var name = String(after[..<close.lowerBound])
            if let pipe = name.firstIndex(of: "|") { name = String(name[..<pipe]) }
            name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains("\n"), !name.contains("[["),
               seen.insert(name.lowercased()).inserted {
                result.append(name)
            }
            rest = after[close.upperBound...]
        }
        return result
    }
}

enum DurationFormat {
    /// 45 → "<1 min", 1500 → "25 min", 4800 → "1h 20m"
    static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

enum DayFormat {
    /// "Today", "Tomorrow", or "Tue, Nov 4".
    static func label(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

enum IntervalFormat {
    /// An amount of time on its own: 30 → "30 min", 60 → "1 hour", 120 → "2 hours", 1440 → "1 day".
    /// (Unlike `short`, which reads "hour" for use after "every".)
    static func amount(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 1440 == 0 { let d = minutes / 1440; return d == 1 ? "1 day" : "\(d) days" }
        if minutes % 60 == 0 { let h = minutes / 60; return h == 1 ? "1 hour" : "\(h) hours" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// 8 → "8 min", 60 → "hour", 90 → "1h 30m", 120 → "2 hours", 1440 → "day"
    static func short(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 1440 == 0 {
            let d = minutes / 1440
            return d == 1 ? "day" : "\(d) days"
        }
        if minutes % 60 == 0 {
            let h = minutes / 60
            return h == 1 ? "hour" : "\(h) hours"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
