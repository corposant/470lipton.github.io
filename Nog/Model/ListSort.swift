import Foundation

/// The List tab's one Sort menu. Table, Agenda and Overview all read it: the Table by
/// column, the Agenda within a time slot, the Overview at the top level.
enum ListSort: String, CaseIterable, Identifiable {
    // Raw values are saved in settings: don't rename them. The menu shows `label`.
    case next = "Next"
    case name = "Name"
    case priority = "Priority"
    case alarms = "Alarms"
    case tags = "Tags"
    case steps = "Steps left"
    case added = "Added"

    var id: String { rawValue }

    /// The name in the Sort menu.
    var label: String {
        switch self {
        case .next: "Next"
        case .name: "Name"
        case .priority: "Priority"
        case .alarms: "Alarms"
        case .tags: "Tags"
        case .steps: "Steps left"
        case .added: "Date added"
        }
    }

    /// What the order means, for VoiceOver after "Sorted by …".
    var spokenOrder: String {
        switch self {
        case .next: "soonest first"
        case .name: "A to Z"
        case .priority: "urgent first, then soonest"
        case .alarms: "loudest first"
        case .tags: "by first tag, A to Z"
        case .steps: "fewest steps left first"
        case .added: "newest first"
        }
    }

    static let key = "listSort"
    static let reversedKey = "listSortReversed"
    static let urgentFirstKey = "listUrgentFirst"
    static let showDoneKey = "listShowsDone"

    /// `items` in this order. Urgent ones go first when `urgentFirst` is on. Nogs missing
    /// the value (no time, no steps, no tags, no reminder) always go last, even reversed.
    /// Ties fall back to the title, then the id, so rows never shuffle between renders.
    /// `globalEscalateAfter` is Settings › "Ring as an alarm after", for the Alarms sort.
    func sorted(_ items: [Item], now: Date, stats: ChildStats,
                reversed: Bool = false, urgentFirst: Bool = true,
                globalEscalateAfter: Int = UserDefaults.standard.integer(forKey: NogSettings.Key.escalateAfter)) -> [Item] {
        // Compute expensive keys once per item, not per comparison.
        let keys = Dictionary(items.compactMap { item in
            key(item, now: now, stats: stats, globalEscalateAfter: globalEscalateAfter).map { (item.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        return items.sorted { a, b in
            if urgentFirst, a.urgent != b.urgent { return a.urgent }
            let ka = keys[a.id], kb = keys[b.id]
            if (ka == nil) != (kb == nil) { return ka != nil }
            if let ka, let kb {
                let order = ka.compare(kb)
                if order != .orderedSame { return reversed ? order == .orderedDescending : order == .orderedAscending }
            }
            let title = a.title.localizedStandardCompare(b.title)
            if title != .orderedSame { return title == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Smaller sorts first. nil = this nog has nothing to sort by.
    private func key(_ item: Item, now: Date, stats: ChildStats, globalEscalateAfter: Int) -> SortKey? {
        let nextTime = item.nextDate(after: now)?.timeIntervalSinceReferenceDate
        switch self {
        case .next:
            return nextTime.map { .numbers([$0]) }
        case .name:
            return .text(item.title)
        case .priority:
            // Urgent first, then whatever asks for attention soonest; nogs with no time
            // come after the timed ones at the same urgency.
            return .numbers([item.urgent ? 0 : 1, nextTime ?? .infinity])
        case .alarms:
            // Loudest first: rings as an alarm, then can ring as one after ignored nogs,
            // then plain sound, then silent. Within each, the shortest gap between nogs.
            guard item.status == .open || item.status == .doing, let r = item.reminder else { return nil }
            let tier: Double
            if r.alarm && !r.silent { tier = 0 }
            else if !r.silent && (r.escalateAfter ?? globalEscalateAfter) > 0 { tier = 1 }
            else if !r.silent { tier = 2 }
            else { tier = 3 }
            let gap = r.repeatMinutes.map { Double(max(1, $0)) } ?? .infinity
            return .numbers([tier, gap, nextTime ?? .infinity])
        case .tags:
            // Grouped by the first tag in A to Z order, so nogs that share it sit together.
            return item.tags.min { $0.localizedStandardCompare($1) == .orderedAscending }.map { .text($0) }
        case .steps:
            let counts = stats[item.id]
            return counts.total > 0 ? .numbers([Double(counts.total - counts.done)]) : nil
        case .added:
            // Newest first.
            return .numbers([-item.created.timeIntervalSinceReferenceDate])
        }
    }
}

/// A sort value: a run of numbers compared in turn, or text compared the way Finder does.
private enum SortKey {
    case numbers([Double])
    case text(String)

    func compare(_ other: SortKey) -> ComparisonResult {
        switch (self, other) {
        case let (.text(a), .text(b)):
            return a.localizedStandardCompare(b)
        case let (.numbers(a), .numbers(b)):
            for (x, y) in zip(a, b) where x != y { return x < y ? .orderedAscending : .orderedDescending }
            return a.count == b.count ? .orderedSame : (a.count < b.count ? .orderedAscending : .orderedDescending)
        default:
            return .orderedSame
        }
    }
}

extension Item {
    /// The Overview's top level among `items`: nogs with no parent, or whose parent isn't in
    /// `items` (gone, or a finished one that's hidden). A nog stuck in a loop (A inside B
    /// inside A) shows here once, as the loop's first member by id, so it can still be found.
    static func outlineRoots(_ items: [Item]) -> [Item] {
        var byID: [UUID: Item] = [:]
        for item in items { byID[item.id] = item }
        return items.filter { item in
            guard let parentID = item.parentID, var current = byID[parentID] else { return true }
            var seen: [UUID] = [item.id]
            while true {
                if let start = seen.firstIndex(of: current.id) {
                    return item.id == seen[start...].min { $0.uuidString < $1.uuidString }
                }
                seen.append(current.id)
                guard let next = current.parentID, let parent = byID[next] else { return false }
                current = parent
            }
        }
    }

    /// When this next asks for attention: a reminder's start if it hasn't begun, otherwise
    /// its next nog (or when it went off, for a one-off). nil = no time, or finished.
    func nextDate(after now: Date) -> Date? {
        guard status == .open || status == .doing, let r = reminder else { return nil }
        if !r.isActive(at: now) { return r.start }
        return r.nextFire(after: now) ?? r.start
    }
}

/// Sub-item counts for every item, computed once per render instead of per row.
struct ChildStats {
    private var counts: [UUID: (done: Int, total: Int)] = [:]

    init(_ items: [Item]) {
        for item in items {
            guard let parent = item.parentID else { continue }
            var entry = counts[parent] ?? (0, 0)
            entry.total += 1
            if item.status == .done { entry.done += 1 }
            counts[parent] = entry
        }
    }

    subscript(id: UUID) -> (done: Int, total: Int) { counts[id] ?? (0, 0) }
}
