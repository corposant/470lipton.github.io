import SwiftUI

/// A `TimelineView` schedule for screens that show times and "nogging now": it ticks once a
/// minute (when minute-level labels like "in 5 min" change) and at the exact moments something
/// starts or runs out, instead of redrawing every 30 seconds whether or not anything changed.
struct MinuteSchedule: TimelineSchedule {
    /// Minute ticks fall on this date's seconds (e.g. a countdown to it). nil = on the clock's minutes.
    var anchor: Date? = nil
    /// Extra moments to tick at: a nog starting, a timebox running out.
    var moments: [Date] = []

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(start: startDate, anchor: anchor?.timeIntervalSinceReferenceDate ?? 0,
                moments: moments.filter { $0 > startDate }.sorted())
    }

    struct Entries: Sequence, IteratorProtocol {
        let start: Date
        let anchor: TimeInterval
        let moments: [Date]
        private var last: Date?
        private var index = 0

        init(start: Date, anchor: TimeInterval, moments: [Date]) {
            self.start = start
            self.anchor = anchor
            self.moments = moments
        }

        mutating func next() -> Date? {
            guard let last else {
                self.last = start
                return start
            }
            // The next whole minute after `last`, counted from the anchor.
            let elapsed = last.timeIntervalSinceReferenceDate - anchor
            var tick = Date(timeIntervalSinceReferenceDate: anchor + (floor(elapsed / 60) + 1) * 60)
            while index < moments.count, moments[index] <= last { index += 1 }
            if index < moments.count, moments[index] < tick { tick = moments[index] }
            self.last = tick
            return tick
        }
    }
}

extension MinuteSchedule {
    /// Ticks for a list of items: each start or timebox end in the coming day.
    static func forItems(_ items: some Sequence<Item>, now: Date = .now) -> MinuteSchedule {
        let horizon = now.addingTimeInterval(86_400)
        var moments: [Date] = []
        for item in items {
            if item.isOpen, let start = item.reminder?.start, start > now, start < horizon { moments.append(start) }
            if let end = item.timeboxEnd, end > now, end < horizon { moments.append(end) }
        }
        return MinuteSchedule(moments: moments)
    }
}
