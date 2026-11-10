import Foundation

/// The lists a Nogitivity widget can pick from (set by press and hold › Edit Widget).
enum WidgetListKind: String, CaseIterable, Codable {
    case now, nogging, today, agenda, loose, dream

    var title: String {
        switch self {
        case .now: "Now"
        case .nogging: "Nogging now"
        case .today: "Today"
        case .agenda: "Agenda"
        case .loose: "Loose nogs"
        case .dream: "Dream nogs"
        }
    }
}

/// Chooses which nogs a widget offers to start, in the order it shows them.
/// Pure, so it's shared by the widget and the tests.
enum WidgetPicker {
    struct Section: Equatable {
        /// nil for "Your picks" (nogs chosen one by one).
        var kind: WidgetListKind?
        var title: String
        var entries: [WidgetSnapshot.Entry]
    }

    /// - Parameters:
    ///   - lists: lists to show, in order. Each nog appears once, in the first list it fits.
    ///   - tag: only nogs with this #tag (any capitalisation, "#" optional).
    ///   - pinned: nogs picked one by one; when set, these replace the lists.
    ///   - excluding: usually the nog you're doing, which the timer already shows.
    static func sections(_ snapshot: WidgetSnapshot, lists: [WidgetListKind], tag: String? = nil,
                         pinned: [UUID] = [], excluding: UUID? = nil, at date: Date,
                         calendar: Calendar = .current) -> [Section] {
        let wanted = tag.map(cleanTag).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let candidates = snapshot.entries.filter { entry in
            !entry.isDoing && entry.id != excluding
                && (wanted == nil || entry.tags.contains { $0.lowercased() == wanted })
        }

        if !pinned.isEmpty {
            let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let picks = pinned.compactMap { byID[$0] }
            return picks.isEmpty ? [] : [Section(kind: nil, title: "Your picks", entries: picks)]
        }

        let weekEnd = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: date)) ?? date
        let soonestFirst: (WidgetSnapshot.Entry, WidgetSnapshot.Entry) -> Bool = {
            let a = $0.when(at: date) ?? .distantFuture, b = $1.when(at: date) ?? .distantFuture
            return a != b ? a < b : $0.title < $1.title
        }
        let newestFirst: (WidgetSnapshot.Entry, WidgetSnapshot.Entry) -> Bool = { $0.updated > $1.updated }

        var used = Set<UUID>()
        var result: [Section] = []
        for kind in lists where !result.contains(where: { $0.kind == kind }) {
            var entries: [WidgetSnapshot.Entry]
            switch kind {
            case .now:
                // Everything about the present: nogging now (alarms, then longest nogging),
                // then the rest of today, soonest first.
                let nogging = candidates.filter { $0.isNogging(at: date) }
                    .sorted { a, b in
                        a.alarm != b.alarm ? a.alarm : (a.start ?? date) < (b.start ?? date)
                    }
                let laterToday = candidates.filter { e in
                    e.isOpen && !e.isNogging(at: date)
                        && e.when(at: date).map { $0 > date && calendar.isDate($0, inSameDayAs: date) } == true
                }
                .sorted(by: soonestFirst)
                entries = nogging + laterToday
            case .nogging:
                // Longest nogging first.
                entries = candidates.filter { $0.isNogging(at: date) }
                    .sorted { ($0.start ?? date) < ($1.start ?? date) }
            case .today:
                entries = candidates.filter { e in
                    e.isOpen && (e.isNogging(at: date) || e.when(at: date).map { calendar.isDate($0, inSameDayAs: date) } == true)
                }
                .sorted { a, b in
                    let an = a.isNogging(at: date), bn = b.isNogging(at: date)
                    return an != bn ? an : soonestFirst(a, b)
                }
            case .agenda:
                entries = candidates.filter { e in
                    e.isOpen && e.start != nil && (e.isNogging(at: date) || (e.when(at: date).map { $0 < weekEnd } ?? false))
                }
                .sorted(by: soonestFirst)
            case .loose:
                entries = candidates.filter { $0.isOpen && $0.start == nil }.sorted(by: newestFirst)
            case .dream:
                entries = candidates.filter(\.isDream).sorted(by: newestFirst)
            }
            entries.removeAll { used.contains($0.id) }
            used.formUnion(entries.map(\.id))
            if !entries.isEmpty { result.append(Section(kind: kind, title: kind.title, entries: entries)) }
        }
        return result
    }

    /// "#Big trip " → "Big-trip", like `Item.cleanTag` (which the widget extension doesn't compile).
    static func cleanTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#,"))
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// Moments when a widget's content changes by itself: a nog starts nogging, a timebox runs out.
    static func changeDates(_ snapshot: WidgetSnapshot, after date: Date, within hours: Double = 24,
                            limit: Int = 40) -> [Date] {
        let horizon = date.addingTimeInterval(hours * 3600)
        var dates = Set<Date>()
        for entry in snapshot.entries {
            if entry.isOpen, let start = entry.start, start > date, start < horizon { dates.insert(start) }
            if let end = entry.timeboxEnd, end > date, end < horizon { dates.insert(end) }
        }
        return Array(dates.sorted().prefix(limit))
    }
}

enum BoxFormat {
    /// The timebox on a ▶︎ button: 15 → "15m", 60 → "1h", 90 → "1h30".
    static func short(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }
}
