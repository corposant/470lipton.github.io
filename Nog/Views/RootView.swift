import AppIntents
import SwiftUI

/// The full overview (Nogs tab).
struct NogsTab: View {
    @Environment(Router.self) private var router
    @State private var search = ""
    @State private var showSettings = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            // Re-render every 30s so "in 5 min" / "nogging now" stay current.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ItemListView(now: context.date, search: search)
            }
            .background { NogBackground() }
            .navigationTitle("NOG")
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}

struct ItemListView: View {
    @Environment(ItemStore.self) private var store
    let now: Date
    let search: String

    var body: some View {
        let all = Array(store.items.values)
        let stats = ChildStats(all)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if all.isEmpty {
            ContentUnavailableView("Nothing captured yet",
                                   systemImage: "tray",
                                   description: Text("Capture something on the Capture tab. Everything nogs you until it's done."))
        } else if !query.isEmpty {
            let results = all
                .filter { $0.title.lowercased().contains(query) || $0.body.lowercased().contains(query)
                    || $0.tags.contains { $0.lowercased().contains(query) } }
                .sorted { $0.updated > $1.updated }
            List {
                Section {
                    ForEach(results) { ItemRow(item: $0, now: now, stats: stats) }
                } header: {
                    SectionLabel(title: "Results", count: results.count)
                }
                .listRowBackground(Theme.glass)
            }
            .nogListStyle()
        } else {
            let doing = all.filter(\.isDoing)
                .sorted { ($0.doingSince ?? .distantPast) < ($1.doingSince ?? .distantPast) }
            let open = all.filter(\.isOpen)
            let due = open.filter { $0.reminder?.isActive(at: now) == true }
                .sorted { $0.reminder!.start < $1.reminder!.start }
            let upcoming = open.filter { $0.reminder.map { !$0.isActive(at: now) } ?? false }
                .sorted { $0.reminder!.start < $1.reminder!.start }
            let laterToday = upcoming.filter { Calendar.current.isDate($0.reminder!.start, inSameDayAs: now) }
            let onDeck = upcoming.filter { !Calendar.current.isDate($0.reminder!.start, inSameDayAs: now) }
            let ideas = open.filter { $0.reminder == nil }
                .sorted { $0.updated > $1.updated }
            let someday = all.filter { $0.status == .someday }
                .sorted { $0.updated > $1.updated }
            let done = all.filter { $0.status == .done }
                .sorted { ($0.completed ?? $0.updated) > ($1.completed ?? $1.updated) }

            List {
                if !doing.isEmpty {
                    Section {
                        ForEach(doing) { item in
                            DoingCard(item: item)
                                .appEntityIdentifier(EntityIdentifier(for: ReminderEntity.self, identifier: item.id))
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        }
                    } header: {
                        SectionLabel(title: "Nogitivity", tint: Theme.blue)
                    }
                }
                section("Nogging now", due, stats: stats)
                section("Later today", laterToday, stats: stats)
                section("Nogs next", onDeck, stats: stats)
                section("Loose nogs", ideas, stats: stats)
                section("Dream nogs", someday, stats: stats, dreamy: true)
                if !done.isEmpty {
                    Section {
                        DisclosureGroup {
                            ForEach(done.prefix(50)) { ItemRow(item: $0, now: now, stats: stats) }
                        } label: {
                            Text("\(done.count) finished").font(.nogMeta).foregroundStyle(Theme.muted)
                        }
                    } header: {
                        SectionLabel(title: "Nogged")
                    }
                    .listRowBackground(Theme.glass)
                }
            }
            .nogListStyle()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Item], stats: ChildStats, dreamy: Bool = false) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { ItemRow(item: $0, now: now, stats: stats) }
            } header: {
                SectionLabel(title: title, count: items.count, tint: dreamy ? Theme.violet : Theme.muted)
            }
            .listRowBackground(dreamy ? AnyView(DreamHaze()) : AnyView(Theme.glass))
        }
    }
}

/// Sub-item counts for every item, computed once per render instead of per row.
struct ChildStats {
    private var counts: [UUID: (done: Int, total: Int)] = [:]

    init(_ items: [Item]) {
        for item in items {
            guard let parent = item.parentID else { continue }
            var entry = counts[parent] ?? (0, 0)
            entry.total += 1
            if item.status == .done { entry.done += 1 }
            counts[parent] = entry
        }
    }

    subscript(id: UUID) -> (done: Int, total: Int) { counts[id] ?? (0, 0) }
}

struct ItemRow: View {
    @Environment(ItemStore.self) private var store
    let item: Item
    let now: Date
    var stats: ChildStats? = nil

    var body: some View {
        HStack(spacing: 8) {
            NavigationLink(value: item.id) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .strikethrough(item.status == .done)
                            .foregroundStyle(item.status == .done ? .secondary : .primary)
                        detailLine
                    }
                }
            }
            if item.status == .open || item.status == .someday {
                StartButton(item: item, subItems: counts.total > 0 ? counts : nil)
            }
        }
        // iOS 27: Siri can act on whichever row you're looking at.
        .appEntityIdentifier(EntityIdentifier(for: ReminderEntity.self, identifier: item.id))
        .swipeActions(edge: .leading) {
            if item.status == .done {
                Button("Reopen") { store.reopen(item.id) }.tint(Theme.violet)
            } else {
                Button("Done") { store.markDone(item.id) }.tint(Theme.blue)
                if !item.isDoing {
                    Button("Start") { store.start(item.id) }.tint(Theme.violet)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { store.delete(item.id) }
            if item.status == .open || item.status == .someday {
                Button {
                    store.snooze(item.id, until: now.addingTimeInterval(TimeInterval(NogSettings.snoozeMinutes * 60)))
                } label: {
                    Label("Snooze \(IntervalFormat.amount(NogSettings.snoozeMinutes))", systemImage: "zzz")
                }
                .tint(Theme.pink)
                Button {
                    store.snooze(item.id, until: NogSettings.nextMorning(after: now))
                } label: {
                    Label(NogSettings.morningLabel, systemImage: "sunrise")
                }
                .tint(Theme.violet)
            } else if item.isDoing {
                Button("+10 min") { store.extend(item.id, minutes: 10) }.tint(Theme.pink)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        // Pink = nogging, violet = coming up, blue = live/done, gray = idea.
        if item.status == .done {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.blue)
        } else if item.isDoing {
            Image(systemName: "play.circle").foregroundStyle(Theme.blue)
        } else if let r = item.reminder, item.isOpen {
            Image(systemName: r.alarm ? "alarm" : "bell")
                .foregroundStyle(r.isActive(at: now) ? Theme.pink : Theme.violet)
        } else {
            Image(systemName: "lightbulb").foregroundStyle(Theme.muted)
        }
    }

    private var counts: (done: Int, total: Int) {
        stats?[item.id] ?? ChildStats(Array(store.items.values))[item.id]
    }

    private var detailLine: some View {
        let counts = self.counts
        let childCount = counts.total
        var parts: [String] = []
        if let text = reminderText { parts.append(text) }
        if item.isDoing, let end = item.timeboxEnd {
            parts.append(end > now ? "Doing · \(end.formatted(.relative(presentation: .named))) left" : "Doing · time's up")
        } else if item.isDoing {
            parts.append("Doing · open-ended")
        }
        if item.status == .done, item.timeSpent >= 60 {
            parts.append("took \(DurationFormat.short(item.timeSpent))")
        } else if item.status != .done, let estimate = item.estimateMinutes {
            parts.append("~\(IntervalFormat.amount(estimate))")
        }
        if childCount > 0 {
            parts.append("\(counts.done)/\(childCount) sub-items")
        }
        if let parent = store.parent(of: item) { parts.append("in \(parent.title)") }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#\($0)" }.joined(separator: " ")) }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var reminderText: String? {
        guard item.isOpen, let r = item.reminder else { return nil }
        if !r.isActive(at: now) {
            let when = r.start.formatted(.relative(presentation: .named))
            if let summary = r.repeatSummary { return "Starts \(when), then \(summary)" }
            return "Reminds once, \(r.start.formatted(date: .omitted, time: .shortened)) · \(when)"
        }
        if r.repeatMinutes != nil, let next = r.nextFire(after: now) {
            return "Nogging until done · next \(next.formatted(.relative(presentation: .named)))"
                + (r.curve == .logarithmic ? " · easing off" : "")
        }
        return "Reminded once, \(r.start.formatted(.relative(presentation: .named)))"
    }
}

/// A faint lavender haze behind Dream nogs.
struct DreamHaze: View {
    var body: some View {
        ZStack {
            Theme.glass
            LinearGradient(colors: [Theme.violet.opacity(0.14), Theme.pink.opacity(0.05), Theme.violet.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
