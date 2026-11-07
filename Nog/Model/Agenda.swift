import Foundation

/// The Agenda tab's content: only things with a time, from now through the coming week.
/// (Untimed and just-caught items live on the Nogs tab.)
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

    /// Open items with a reminder, grouped: Nogging now · Later today · Tomorrow · This week.
    static func groups(_ items: [Item], now: Date, policy: NogPolicy = .standard, days: Int = 7,
                       calendar: Calendar = .current) -> [Group] {
        let horizon = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
        var nogging: [Entry] = [], today: [Entry] = [], tomorrow: [Entry] = [], week: [Entry] = []
        for item in items {
            guard item.isOpen, let r = item.reminder else { continue }
            let isNogging = r.start <= now
            let upcoming = policy.deliveryDates(for: r, after: isNogging ? now : r.start.addingTimeInterval(-1),
                                                limit: 1, calendar: calendar).first
            // A one-off that already went off is still nogging you, with nothing more scheduled.
            guard let next = upcoming ?? (isNogging ? r.start : nil) else { continue }
            let entry = Entry(item: item, when: next, isNogging: isNogging)
            if isNogging {
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
            Group(title: "Nogging now", entries: nogging),
            Group(title: "Later today", entries: today.sorted(by: byTime)),
            Group(title: "Tomorrow", entries: tomorrow.sorted(by: byTime)),
            Group(title: "This week", entries: week.sorted(by: byTime)),
        ].filter { !$0.entries.isEmpty }
    }
}
