import Foundation
import WidgetKit

/// Keeps the widgets' snapshot (see `WidgetSnapshot`) in step with your items.
@MainActor
enum WidgetSync {
    /// What the widgets were last given, so unchanged data doesn't reload them.
    private static var lastKey: Data?
    private static var lastPolicy: NogPolicy?
    private static var lastReminders: [UUID: Reminder] = [:]
    private static var lastNextNogs: [UUID: Date] = [:]

    /// Writes a fresh snapshot to the App Group and reloads the widgets if anything changed.
    ///
    /// Each entry's "next nog" moves forward on its own as time passes, so it isn't compared
    /// directly (that made nearly every sync reload the widgets, using up their daily budget).
    /// It counts as a change only when a rhythm or the quiet-hours policy changed, or when a
    /// next nog the widgets are showing has gone by.
    static func publish(_ items: [Item], now: Date = .now) {
        guard let url = WidgetStore.fileURL else { return } // no App Group (e.g. a free account)
        let signpost = Perf.signposter.beginInterval("Widget publish")
        defer { Perf.signposter.endInterval("Widget publish", signpost) }
        let policy = NogSettings.policy
        let snapshot = Self.snapshot(items, now: now, policy: policy,
                                     defaultTimebox: NogSettings.timeboxMinutes,
                                     showTitles: NogSettings.showTitles,
                                     appearance: NogSettings.themeMode)
        var comparable = snapshot
        comparable.generated = .distantPast
        for i in comparable.entries.indices { comparable.entries[i].nextNog = nil }
        var reminders: [UUID: Reminder] = [:]
        for item in items { if let r = item.reminder { reminders[item.id] = r } }
        var nextNogs: [UUID: Date] = [:]
        for entry in snapshot.entries { if let next = entry.nextNog { nextNogs[entry.id] = next } }
        let shownNogPassed = lastNextNogs.contains { id, date in date <= now && nextNogs[id] != date }

        guard let key = WidgetStore.encode(comparable),
              key != lastKey || policy != lastPolicy || reminders != lastReminders || shownNogPassed,
              let data = WidgetStore.encode(snapshot) else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastKey = key
            lastPolicy = policy
            lastReminders = reminders
            lastNextNogs = nextNogs
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("Nog: couldn't write the widget snapshot: \(error)")
        }
    }

    /// Everything not yet nogged, with what the widgets need to show and start it.
    nonisolated static func snapshot(_ items: [Item], now: Date, policy: NogPolicy, defaultTimebox: Int,
                                     showTitles: Bool, appearance: ThemeMode = .auto,
                                     calendar: Calendar = .current) -> WidgetSnapshot {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [UUID: [Item]] = [:]
        for item in items { if let p = item.parentID { children[p, default: []].append(item) } }

        let history = TimeboxAdvisor.history(in: items)

        let entries = items.filter { $0.status != .done }.map { item -> WidgetSnapshot.Entry in
            var next: Date?
            if item.isOpen, let r = item.reminder {
                let isNogging = r.start <= now
                next = policy.deliveryDates(for: r, after: isNogging ? now : r.start.addingTimeInterval(-1),
                                            limit: 1, calendar: calendar).first
            }
            let kids = (children[item.id] ?? []).sorted { $0.created < $1.created }
            let subs = (kids.filter { $0.status != .done } + kids.filter { $0.status == .done })
                .prefix(5)
                .map { WidgetSnapshot.SubItem(title: $0.title, done: $0.status == .done) }
            let suggestion = TimeboxAdvisor.suggest(for: item, history: history, defaultMinutes: defaultTimebox, now: now)
            return WidgetSnapshot.Entry(
                id: item.id,
                title: item.title,
                status: item.status.rawValue,
                tags: item.tags,
                parentTitle: item.parentID.flatMap { byID[$0]?.title },
                start: item.reminder?.start,
                nextNog: next,
                alarm: item.reminder?.alarm ?? false,
                suggestedMinutes: suggestion.minutes,
                doingSince: item.doingSince,
                timeboxMinutes: item.timeboxMinutes,
                subItems: Array(subs),
                subDone: kids.filter { $0.status == .done }.count,
                subTotal: kids.count,
                updated: item.updated)
        }
        .sorted { $0.updated > $1.updated }

        return WidgetSnapshot(generated: now, entries: entries, showTitlesOnLockScreen: showTitles,
                              appearance: appearance == .auto ? nil : appearance.rawValue)
    }
}
