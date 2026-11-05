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
    var tags: [String] = []
    var reminder: Reminder?

    var isOpen: Bool { status == .open }

    /// Titles referenced with [[wiki links]] in the body.
    var outgoingLinkTitles: [String] { LinkParser.links(in: body) }
}

enum ItemStatus: String, CaseIterable, Hashable {
    case open, someday, done

    var label: String {
        switch self {
        case .open: "Open"
        case .someday: "Someday"
        case .done: "Done"
        }
    }
}

/// How the gap between nogs behaves.
enum RepeatCurve: String, CaseIterable, Hashable {
    /// Same gap every time: 8, 8, 8, 8…
    case steady
    /// Gap doubles each time, capped at a day: 8, 16, 32, 64… then daily, forever.
    case logarithmic

    var label: String {
        switch self {
        case .steady: "Steady"
        case .logarithmic: "Logarithmic"
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

    /// Logarithmic gaps stop growing here.
    static let logarithmicCapMinutes = 1440

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
        }
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

enum IntervalFormat {
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
