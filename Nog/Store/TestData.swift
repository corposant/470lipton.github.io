#if DEBUG
import Foundation

/// Debug builds only: fills the store with realistic-looking items so slow paths
/// (reloads, syncs, the Map, long lists) show up in Instruments. Every test item
/// carries the #perftest tag so they can all be removed again.
extension ItemStore {
    static let testTag = "perftest"

    func addTestItems(count: Int = 300, now: Date = .now) {
        let words = ["Call", "Email", "Fix", "Buy", "Plan", "Draft", "Book", "Review", "Clean", "Pay",
                     "Water", "Return", "Order", "Sort", "Write", "Check", "Move", "Read", "Pick up", "Cancel"]
        let things = ["the dentist", "mom", "the sink", "groceries", "the trip", "the report", "flights",
                      "the PR", "the garage", "rent", "the plants", "library books", "printer ink",
                      "receipts", "a thank-you note", "the tyres", "the couch", "chapter 3", "the parcel", "the gym"]
        let tags = ["home", "work", "calls", "errands", "kitchen", "health", "money", "car"]
        var titles: [String] = []
        batch {
            var parents: [UUID] = []
            for i in 0..<count {
                let title = "\(words[i % words.count]) \(things[(i / words.count + i) % things.count]) \(i)"
                var item = Item(title: title, created: now.addingTimeInterval(-Double(count - i) * 600))
                item.tags = [Self.testTag, tags[i % tags.count]]
                if i % 7 == 0, let earlier = titles.randomElement() {
                    item.body = "Notes for \(title). See [[\(earlier)]]."
                }
                if i % 5 == 1, let parent = parents.last { item.parentID = parent }
                switch i % 6 {
                case 0: // starts in a few days, every half hour
                    item.reminder = Reminder(start: now.addingTimeInterval(Double(2 + i % 5) * 86_400), repeatMinutes: 30)
                case 1: // later this week, once
                    item.reminder = Reminder(start: now.addingTimeInterval(Double(1 + i % 4) * 86_400 + 3600))
                case 2:
                    item.status = .done
                    item.completed = now.addingTimeInterval(-Double(i) * 300)
                    item.timeSpent = Double(5 + i % 40) * 60
                case 3:
                    item.status = .someday
                default:
                    break // a loose idea
                }
                insert(item)
                titles.append(title)
                if i % 10 == 0 { parents.append(item.id) }
            }
        }
    }

    func removeTestItems() {
        batch {
            for item in items.values where item.tags.contains(Self.testTag) { delete(item.id) }
        }
    }
}
#endif
