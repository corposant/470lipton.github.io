import Foundation

/// The List tab's one Sort menu. Table, Agenda and Overview all read it: the Table by
/// column, the Agenda within a time slot, the Overview at the top level.
enum ListSort: String, CaseIterable, Identifiable {
    case next = "Next"
    case name = "Name"
    case steps = "Steps left"
    case added = "Added"

    var id: String { rawValue }

    static let key = "listSort"
    static let reversedKey = "listSortReversed"
    static let urgentFirstKey = "listUrgentFirst"
    static let showDoneKey = "listShowsDone"

    /// `items` in this order. Urgent ones go first when `urgentFirst` is on. Nogs missing
    /// the value (no time, no steps) always go last, even reversed. Ties fall back to the
    /// title, then the id, so rows never shuffle between renders.
    func sorted(_ items: [Item], now: Date, stats: ChildStats,
                reversed: Bool = false, urgentFirst: Bool = true) -> [Item] {
        items.sorted { a, b in
            if urgentFirst, a.urgent != b.urgent { return a.urgent }
            if self == .name {
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return reversed ? order == .orderedDescending : order == .orderedAscending }
            } else {
                let ka = key(a, now: now, stats: stats), kb = key(b, now: now, stats: stats)
                if (ka == nil) != (kb == nil) { return ka != nil }
                if let ka, let kb, ka != kb { return reversed ? ka > kb : ka < kb }
            }
            let title = a.title.localizedStandardCompare(b.title)
            if title != .orderedSame { return title == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Smaller sorts first. nil = this nog has nothing to sort by.
    private func key(_ item: Item, now: Date, stats: ChildStats) -> Double? {
        switch self {
        case .next:
            return item.nextDate(after: now)?.timeIntervalSinceReferenceDate
        case .name:
            return nil
        case .steps:
            let counts = stats[item.id]
            return counts.total > 0 ? Double(counts.total - counts.done) : nil
        case .added:
            // Newest first.
            return -item.created.timeIntervalSinceReferenceDate
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
