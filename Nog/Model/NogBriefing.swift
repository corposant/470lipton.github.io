import Foundation

/// Spoken summaries of your nogs, for Siri (hands-free, e.g. in CarPlay).
/// Short, in plain sentences, at most a handful of items each.
enum NogBriefing {
    enum Section: String, CaseIterable {
        /// What's nogging you right now.
        case now
        /// Nogging now, plus the rest of today.
        case today
        /// Everything timed through the week (the Agenda tab).
        case agenda
        /// Open things with no time (Loose nogs).
        case loose
        /// What you're working on (Nogitivity).
        case doing
    }

    static func text(for section: Section, items: [Item], now: Date, policy: NogPolicy = .standard,
                     limit: Int = 5, calendar: Calendar = .current) -> String {
        let groups = Agenda.groups(items, now: now, policy: policy, calendar: calendar)
        func entries(_ titles: [String]) -> [Agenda.Entry] {
            groups.filter { titles.contains($0.title) }.flatMap(\.entries)
        }
        switch section {
        case .now:
            let nogging = entries(["Now"])
            guard !nogging.isEmpty else { return "Nothing's nogging you right now." }
            return "\(count(nogging.count, "thing is", "things are")) nogging: \(list(nogging.map(\.item.title), limit: limit))."
        case .today:
            let nogging = entries(["Now"]), later = entries(["Later today"])
            if nogging.isEmpty && later.isEmpty { return "Nothing else today." }
            var parts: [String] = []
            if !nogging.isEmpty { parts.append("Now: \(list(nogging.map(\.item.title), limit: limit)).") }
            if !later.isEmpty {
                parts.append("Later today: \(list(later.map { "\($0.item.title) at \(time($0.when))" }, limit: limit)).")
            }
            return parts.joined(separator: " ")
        case .agenda:
            let upcoming = entries(["Later today", "Tomorrow", "This week"])
            let nogging = entries(["Now"]).count
            guard nogging > 0 || !upcoming.isEmpty else { return "Nothing with a time this week." }
            var parts: [String] = []
            if nogging > 0 { parts.append("\(count(nogging, "thing is", "things are")) nogging now.") }
            if !upcoming.isEmpty {
                parts.append("Coming up: \(list(upcoming.map { "\($0.item.title) \(when($0.when, now: now, calendar: calendar))" }, limit: limit)).")
            }
            return parts.joined(separator: " ")
        case .loose:
            let loose = items.filter { $0.isOpen && $0.reminder == nil }.sorted { $0.updated > $1.updated }
            guard !loose.isEmpty else { return "Nothing without a reminder." }
            return "\(count(loose.count, "thing without a reminder", "things without a reminder")): \(list(loose.map(\.title), limit: limit))."
        case .doing:
            let doing = items.filter(\.isDoing)
            guard !doing.isEmpty else { return "You're not working on anything right now." }
            let lines = doing.prefix(limit).map { item -> String in
                guard let end = item.timeboxEnd else { return "\(item.title), no time limit" }
                let minutes = Int((end.timeIntervalSince(now) / 60).rounded())
                return minutes > 0 ? "\(item.title), \(minutes) minute\(minutes == 1 ? "" : "s") left" : "\(item.title), time's up"
            }
            return "You're on \(lines.joined(separator: "; "))."
        }
    }

    /// "a, b, and 3 more".
    static func list(_ names: [String], limit: Int) -> String {
        let shown = Array(names.prefix(limit))
        let rest = names.count - shown.count
        let all = shown + (rest > 0 ? ["\(rest) more"] : [])
        return all.formatted(.list(type: .and))
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "at 2:00 PM", "tomorrow at 9:00 AM", "Thursday at 9:00 AM".
    private static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time(date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time(date))"
        }
        return "\(date.formatted(.dateTime.weekday(.wide))) at \(time(date))"
    }
}
