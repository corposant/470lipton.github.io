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
    /// Flagged urgent: listed first, and "Done for now" doesn't hold its nogs until tomorrow.
    var urgent = false
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
    /// Urgent ones first, then `then`'s order.
    static func urgentFirst(_ a: Item, _ b: Item, then: (Item, Item) -> Bool) -> Bool {
        a.urgent != b.urgent ? a.urgent : then(a, b)
    }

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
    /// Days, gently getting more frequent: once a day for a week, twice a day the next week
    /// (6 hours apart), then three times a day (3 hours apart), all from the first nog's time of day.
    case balanced
    /// The Nagging profile: every 30 min for the first 3 hours, then every 15.
    case nagging
    /// The Easing profile: steps down every 12 hours through the profiles' paces,
    /// Nagging → Steady → Balanced → Whisper, then stays at Whisper's once a day.
    case easingSteps = "easing_steps"
    /// The Building profile: steps up every 12 hours, Whisper → Balanced → Steady → Nagging,
    /// then nags like Nagging. Never reaches Unhinged and never rings as an alarm.
    case buildingSteps = "building_steps"

    /// The styles offered for a custom rhythm. The rest are profiles' own patterns
    /// (they ignore the repeat gap), so they're only listed when a rhythm already uses one.
    static func customChoices(current: RepeatCurve) -> [RepeatCurve] {
        let plain: [RepeatCurve] = [.steady, .logarithmic, .building]
        return plain.contains(current) ? plain : plain + [current]
    }

    var label: String {
        switch self {
        case .steady: "Steady"
        case .logarithmic: "Logarithmic"
        case .building: "Speeding up"
        case .balanced: "Balanced"
        case .nagging: "Nagging"
        case .easingSteps: "Easing"
        case .buildingSteps: "Building"
        }
    }

    /// Paces that change with time since the rhythm began, not with the number of nogs:
    /// (minutes after the start, gap in minutes) for each stretch. nil for the other styles.
    var timedPhases: [(after: Int, gap: Int)]? {
        let nagging = Pace.nagging, steady = Pace.steady, balanced = Pace.balanced, whisper = Pace.whisper
        let step = Pace.stepMinutes
        switch self {
        case .nagging:
            return [(0, nagging), (Pace.naggingSpeedsUpAfter, Pace.naggingLater)]
        case .easingSteps:
            return [(0, nagging), (step, steady), (2 * step, balanced), (3 * step, whisper)]
        case .buildingSteps:
            // The last step is Nagging itself, so it speeds up 3 hours in, as Nagging does.
            return [(0, whisper), (step, balanced), (2 * step, steady), (3 * step, nagging),
                    (3 * step + Pace.naggingSpeedsUpAfter, Pace.naggingLater)]
        case .steady, .logarithmic, .building, .balanced:
            return nil
        }
    }

    /// Ignores the repeat gap: the pattern is the whole rhythm.
    var hasOwnPattern: Bool { self == .balanced || timedPhases != nil }

    /// The profiles' paces, in minutes, as the Easing and Building steps use them.
    enum Pace {
        static let nagging = 30
        static let naggingLater = 15
        static let naggingSpeedsUpAfter = 180
        static let steady = 150
        /// Balanced at twice a day.
        static let balanced = 360
        /// Whisper once it has eased off to daily.
        static let whisper = 1440
        /// Easing and Building move one step every 12 hours.
        static let stepMinutes = 720
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
    /// Balanced, Nagging, Easing, Building: when their ramp began, if `start` has moved since
    /// (a snooze, Skip today, Done for now). nil = the ramp began at `start`.
    var rampSince: Date? = nil

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
        case .balanced:
            return TimeInterval(Self.balancedGapMinutes(after: k + balancedOffset) * 60)
        case .nagging, .easingSteps, .buildingSteps:
            // Timed paces depend on the clock, not the count: see `gap(at:)`.
            return gap(at: rampOrigin)
        }
    }

    /// When a timed pace (Nagging, Easing, Building) began: `rampSince` once it has moved.
    var rampOrigin: Date {
        if let since = rampSince, since < start { return since }
        return start
    }

    /// The gap after a nog at `date`. For timed paces it's the pace of the stretch `date` is in,
    /// cut short at the next stretch so a nog always lands on the change. Others: the first gap.
    func gap(at date: Date) -> TimeInterval? {
        guard repeatMinutes != nil else { return nil }
        guard let phases = curve.timedPhases else { return gap(after: 0) }
        let elapsed = max(0, date.timeIntervalSince(rampOrigin))
        var pace = TimeInterval(phases[0].gap * 60)
        var nextChange: TimeInterval?
        for phase in phases {
            let at = TimeInterval(phase.after * 60)
            if at <= elapsed { pace = TimeInterval(phase.gap * 60) } else { nextChange = at; break }
        }
        guard let nextChange else { return pace }
        return min(pace, nextChange - elapsed)
    }

    /// When the last timed stretch begins (nil when it's not a timed pace).
    private var lastPhaseStart: Date? {
        curve.timedPhases.map { rampOrigin.addingTimeInterval(TimeInterval(($0.last?.after ?? 0) * 60)) }
    }

    /// How far into Balanced's ramp `start` already is: whole days since `rampSince`, as a count
    /// of nogs, always landing on the first nog of a day so the times of day hold.
    var balancedOffset: Int {
        guard let since = rampSince, since < start else { return 0 }
        var days = Int(start.timeIntervalSince(since) / 86_400)
        var offset = 0
        for (step, pattern) in Self.balancedDayPatterns.enumerated() {
            if step == Self.balancedDayPatterns.count - 1 || days < Self.balancedDaysPerStep {
                // The last step repeats forever, so being anywhere in it is the same.
                return offset + (step == Self.balancedDayPatterns.count - 1 ? 0 : days * pattern.count)
            }
            offset += Self.balancedDaysPerStep * pattern.count
            days -= Self.balancedDaysPerStep
        }
        return offset
    }

    /// This reminder starting at `date` instead (a snooze, Skip today, Done for now). Balanced, Nagging,
    /// Easing and Building remember when their ramp began, so moving them doesn't start them over.
    func moved(to date: Date) -> Reminder {
        var r = self
        if curve.hasOwnPattern, rampSince == nil, start < date { r.rampSince = start }
        r.start = date
        return r
    }

    /// Balanced: nogs a day in week one, then two, then three.
    static let balancedDaysPerStep = 7
    /// The day's gaps at each step, adding up to a day so the nogs keep their time of day:
    /// once (24 h), twice (6 hours apart), three times (3 hours apart).
    /// From Balanced's 10 AM: 10 AM; then 10 AM and 4 PM; then 10 AM, 1 PM and 4 PM.
    static let balancedDayPatterns: [[Int]] = [[1440], [360, 1080], [180, 180, 1080]]

    static func balancedGapMinutes(after k: Int) -> Int {
        var k = max(0, k)
        for (step, pattern) in balancedDayPatterns.enumerated() {
            let count = pattern.count * balancedDaysPerStep
            if k < count || step == balancedDayPatterns.count - 1 { return pattern[k % pattern.count] }
            k -= count
        }
        return 1440
    }

    /// From this moment on the gap never changes again: (moment, gap).
    /// Lets the planner hand iOS a single forever-repeating trigger.
    /// Balanced never settles on one gap (its days have a pattern), so it's always exact times.
    var settledPhase: (since: Date, gap: TimeInterval)? {
        if curve == .balanced { return nil }
        if let last = lastPhaseStart, let pace = gap(at: last) {
            // A nog always lands on each change of pace, so from the last one it's a plain repeat.
            return (max(start, last), pace)
        }
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
        var iterations = 0
        let timed = curve.timedPhases != nil
        while result.count < limit && iterations < 100_000 {
            iterations += 1
            if timed {
                guard let g = gap(at: t), g > 0 else { break }
                // Still in the past: jump ahead through this stretch instead of stepping.
                if t <= date {
                    let end = min(date, nextPhaseChange(after: t) ?? date)
                    let skip = (end.timeIntervalSince(t) / g).rounded(.down)
                    if skip >= 1 {
                        t = t.addingTimeInterval(skip * g)
                        continue
                    }
                }
                if t > date { result.append(t) }
                t = t.addingTimeInterval(g)
                continue
            }
            guard let g = gap(after: k) else { break }
            // In a steady stretch that's still in the past, jump ahead instead of stepping.
            // (Not Balanced: its week of equal day-long gaps is followed by a different pattern.)
            if curve != .balanced, t <= date, let next = gap(after: k + 1), next == g {
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

    /// The next change of a timed pace strictly after `date`, if any is left.
    private func nextPhaseChange(after date: Date) -> Date? {
        guard let phases = curve.timedPhases else { return nil }
        return phases.lazy.map { self.rampOrigin.addingTimeInterval(TimeInterval($0.after * 60)) }
            .first { $0 > date }
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
        case .balanced:
            return "daily, then twice a day, then three times"
        case .nagging:
            return "every 30 min, then every 15 after 3 hours"
        case .easingSteps:
            return "every 30 min, easing off every 12 hours to daily"
        case .buildingSteps:
            return "daily, building every 12 hours to every 30 min"
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
