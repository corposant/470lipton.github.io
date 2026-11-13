import Foundation

/// The Agenda tab's content: only things with a time, from now through the coming week.
/// (Untimed items live on the List tab.)
enum Agenda {
    struct Entry: Identifiable, Equatable {
        let item: Item
        /// When it next actually nogs (quiet hours applied).
        let when: Date
        /// Already nogging (its start has passed).
        let isNogging: Bool
        var id: UUID { item.id }
    }

    struct Group: Identifiable, Equatable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    /// Open items with a reminder that nog now or within `days` days, each at its next nog.
    static func entries(_ items: [Item], now: Date, policy: NogPolicy = .standard, days: Int = 7,
                        calendar: Calendar = .current) -> [Entry] {
        let horizon = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        var result: [Entry] = []
        for item in items {
            guard item.isOpen, let r = item.reminder else { continue }
            let isNogging = r.start <= now
            let upcoming = policy.deliveryDates(for: r, after: isNogging ? now : r.start.addingTimeInterval(-1),
                                                limit: 1, calendar: calendar).first
            // A one-off that already went off is still nogging you, with nothing more scheduled.
            guard let next = upcoming ?? (isNogging ? r.start : nil) else { continue }
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
            if isNogging || next < horizon || calendar.isDate(next, inSameDayAs: now)
                || tomorrow.map({ calendar.isDate(next, inSameDayAs: $0) }) == true {
                result.append(Entry(item: item, when: next, isNogging: isNogging))
            }
        }
        return result
    }

    /// Open items with a reminder, grouped: Nogging now · Later today · Tomorrow · This week.
    static func groups(_ items: [Item], now: Date, policy: NogPolicy = .standard, days: Int = 7,
                       calendar: Calendar = .current) -> [Group] {
        let horizon = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        var nogging: [Entry] = [], today: [Entry] = [], tomorrow: [Entry] = [], week: [Entry] = []
        for entry in entries(items, now: now, policy: policy, days: days, calendar: calendar) {
            let next = entry.when
            if entry.isNogging {
                nogging.append(entry)
            } else if calendar.isDate(next, inSameDayAs: now) {
                today.append(entry)
            } else if let nextDay = calendar.date(byAdding: .day, value: 1, to: now),
                      calendar.isDate(next, inSameDayAs: nextDay) {
                tomorrow.append(entry)
            } else if next < horizon {
                week.append(entry)
            }
        }
        // Nogging longest first; the rest soonest first.
        nogging.sort { ($0.item.reminder?.start ?? $0.when) < ($1.item.reminder?.start ?? $1.when) }
        let byTime: (Entry, Entry) -> Bool = { $0.when != $1.when ? $0.when < $1.when : $0.item.title < $1.item.title }
        return [
            Group(title: "Now", entries: nogging),
            Group(title: "Later today", entries: today.sorted(by: byTime)),
            Group(title: "Tomorrow", entries: tomorrow.sorted(by: byTime)),
            Group(title: "This week", entries: week.sorted(by: byTime)),
        ].filter { !$0.entries.isEmpty }
    }

    /// One planner page: a day and what nogs on it. Today's page starts with everything
    /// nogging now.
    struct Day: Identifiable, Equatable {
        let date: Date
        let entries: [Entry]
        var id: Date { date }
    }

    /// `entries` on day pages from today on, nogging-now first on today's page, then by time.
    /// `order` breaks ties (the List's Sort menu).
    static func days(_ entries: [Entry], now: Date, calendar: Calendar = .current,
                     order: ([Item]) -> [Item] = { $0 }) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [Entry]] = [:]
        for entry in entries {
            let day = entry.isNogging ? today : max(today, calendar.startOfDay(for: entry.when))
            byDay[day, default: []].append(entry)
        }
        return byDay.keys.sorted().map { day in
            let list = byDay[day] ?? []
            let rank = Dictionary(uniqueKeysWithValues: order(list.map(\.item)).enumerated().map { ($1.id, $0) })
            let sorted = list.sorted { a, b in
                if a.isNogging != b.isNogging { return a.isNogging }
                if !a.isNogging, a.when != b.when { return a.when < b.when }
                return (rank[a.item.id] ?? 0) < (rank[b.item.id] ?? 0)
            }
            return Day(date: day, entries: sorted)
        }
    }
}
