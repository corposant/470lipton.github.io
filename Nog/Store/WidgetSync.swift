import Foundation
import WidgetKit

/// Keeps the widgets' snapshot (see `WidgetSnapshot`) in step with your items.
@MainActor
enum WidgetSync {
    /// The last snapshot written, so unchanged data doesn't reload the widgets.
    private static var lastWritten: Data?

    /// Writes a fresh snapshot to the App Group and reloads the widgets if anything changed.
    static func publish(_ items: [Item], now: Date = .now) {
        guard let url = WidgetStore.fileURL else { return } // no App Group (e.g. a free account)
        let snapshot = Self.snapshot(items, now: now, policy: NogSettings.policy,
                                     defaultTimebox: NogSettings.timeboxMinutes,
                                     showTitles: NogSettings.showTitles)
        // `generated` changes every time; compare everything else.
        var comparable = snapshot
        comparable.generated = .distantPast
        guard let key = WidgetStore.encode(comparable), key != lastWritten,
              let data = WidgetStore.encode(snapshot) else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastWritten = key
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("Nog: couldn't write the widget snapshot: \(error)")
        }
    }

    /// Everything not yet nogged, with what the widgets need to show and start it.
    nonisolated static func snapshot(_ items: [Item], now: Date, policy: NogPolicy, defaultTimebox: Int,
                                     showTitles: Bool, calendar: Calendar = .current) -> WidgetSnapshot {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [UUID: [Item]] = [:]
        for item in items { if let p = item.parentID { children[p, default: []].append(item) } }

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
            let suggestion = TimeboxAdvisor.suggest(for: item, among: items, defaultMinutes: defaultTimebox, now: now)
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

        return WidgetSnapshot(generated: now, entries: entries, showTitlesOnLockScreen: showTitles)
    }
}
