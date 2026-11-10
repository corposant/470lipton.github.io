import Foundation

struct TimeboxSuggestion: Equatable {
    /// nil = open-ended (count up)
    var minutes: Int?
    /// Why, in a few words, e.g. "like your other #calls"
    var reason: String

    var label: String {
        guard let minutes else { return "Open-ended" }
        return "\(IntervalFormat.amount(minutes)) · \(reason)"
    }
}

/// Picks a timebox for ▶︎ from the item's own settings, your history with
/// similar items, and how urgent or overdue it is.
enum TimeboxAdvisor {
    static func suggest(for item: Item, among all: [Item], defaultMinutes: Int, now: Date) -> TimeboxSuggestion {
        suggest(for: item, history: history(in: all), defaultMinutes: defaultMinutes, now: now)
    }

    /// The finished items worth learning from. Work it out once when suggesting for many items.
    static func history(in all: [Item]) -> [Item] {
        all.filter { $0.status == .done && $0.timeSpent >= 60 }
    }

    static func suggest(for item: Item, history finished: [Item], defaultMinutes: Int, now: Date) -> TimeboxSuggestion {
        // 1. Your own estimate for this item
        if let estimate = item.estimateMinutes, estimate > 0 {
            return TimeboxSuggestion(minutes: estimate, reason: "your estimate")
        }

        // 2. History: how long similar finished items took
        let history = finished.filter { $0.id != item.id }
        let tags = Set(item.tags.map { $0.lowercased() })
        if !tags.isEmpty {
            var best: (tag: String, items: [Item])?
            for tag in tags.sorted() {
                let similar = history.filter { $0.tags.contains { $0.lowercased() == tag } }
                if similar.count >= 2, similar.count > (best?.items.count ?? 0) { best = (tag, similar) }
            }
            if let best, let minutes = medianMinutes(best.items) {
                return TimeboxSuggestion(minutes: minutes, reason: "like your other #\(best.tag)")
            }
        }
        if let parent = item.parentID {
            let siblings = history.filter { $0.parentID == parent }
            if siblings.count >= 2, let minutes = medianMinutes(siblings) {
                return TimeboxSuggestion(minutes: minutes, reason: "like the other steps here")
            }
        }

        // 3. Urgency
        if let reminder = item.reminder {
            if reminder.alarm {
                return TimeboxSuggestion(minutes: 15, reason: "it's urgent")
            }
            if now.timeIntervalSince(reminder.start) > 86_400 {
                return TimeboxSuggestion(minutes: 10, reason: "it's been waiting, so start small")
            }
        }

        // 4. Your default
        return defaultMinutes > 0
            ? TimeboxSuggestion(minutes: defaultMinutes, reason: "your default")
            : TimeboxSuggestion(minutes: nil, reason: "open-ended")
    }

    /// Median minutes, rounded to 5, between 5 and 240.
    static func medianMinutes(_ items: [Item]) -> Int? {
        let minutes = items.map { $0.timeSpent / 60 }.sorted()
        guard !minutes.isEmpty else { return nil }
        let mid = minutes.count / 2
        let median = minutes.count % 2 == 0 ? (minutes[mid - 1] + minutes[mid]) / 2 : minutes[mid]
        let rounded = Int((median / 5).rounded()) * 5
        return min(240, max(5, rounded))
    }
}
