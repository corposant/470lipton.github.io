import Foundation

/// Defensive storage/intent boundary. Limits are app safety bounds, not OS limits.
enum ItemValidation {
    static let maxIntervalMinutes = 5_256_000
    static let maxTimeboxMinutes = 7 * 24 * 60
    static let maxRecurrenceInterval = 10_000

    static func accepts(_ item: Item) -> Bool {
        guard item.timeSpent.isFinite, (0...1_000_000_000_000).contains(item.timeSpent),
              item.timesDone >= 0, item.timesDone < Int.max,
              item.timeboxMinutes.map({ (1...maxTimeboxMinutes).contains($0) }) ?? true,
              item.checkInMinutes.map({ (0...maxIntervalMinutes).contains($0) }) ?? true else { return false }
        if let r = item.reminder {
            guard r.repeatMinutes.map({ (1...maxIntervalMinutes).contains($0) }) ?? true,
                  r.snoozeMinutes.map({ (1...maxIntervalMinutes).contains($0) }) ?? true,
                  r.escalateAfter.map({ (0...10_000).contains($0) }) ?? true else { return false }
        }
        if let recurrence = item.recurrence {
            switch recurrence.rule {
            case .days(let n), .weeks(let n):
                guard (1...maxRecurrenceInterval).contains(n) else { return false }
            case .weekdays(let days):
                guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else { return false }
            case .monthly(let day):
                guard (1...31).contains(day) else { return false }
            case .yearly(let month, let day):
                guard (1...12).contains(month), (1...31).contains(day) else { return false }
            }
        }
        return true
    }
}
