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

/// When to start nogging, and how often to repeat until the item is done.
struct Reminder: Hashable {
    var start: Date
    /// nil = fire once. Otherwise repeat every N minutes (minimum 1) until done.
    var repeatMinutes: Int?

    var repeatInterval: TimeInterval? {
        repeatMinutes.map { TimeInterval(max(1, $0) * 60) }
    }

    func isActive(at now: Date) -> Bool { start <= now }

    /// Best estimate of the next time this reminder fires.
    func nextFire(after now: Date) -> Date? {
        if start > now { return start }
        guard let interval = repeatInterval else { return nil }
        let k = (now.timeIntervalSince(start) / interval).rounded(.down) + 1
        return start.addingTimeInterval(k * interval)
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
