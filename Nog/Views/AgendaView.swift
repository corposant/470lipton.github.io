import AppIntents
import SwiftUI

/// The Agenda tab: only what has a time, from now through the coming week.
/// Untimed and just-caught things live on the Nogs tab.
struct AgendaView: View {
    @Environment(Router.self) private var router
    @State private var showSettings = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.agendaPath) {
            // Re-render every 30s so times and "nogging now" stay current.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                AgendaList(now: context.date)
            }
            .background { NogBackground() }
            .safeAreaInset(edge: .top) { SilenceBanner() }
            .navigationTitle("Agenda")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

private struct AgendaList: View {
    @Environment(ItemStore.self) private var store
    let now: Date

    var body: some View {
        let all = Array(store.items.values)
        let groups = Agenda.groups(all, now: now, policy: NogSettings.policy)
        let doing = all.filter(\.isDoing).sorted { ($0.doingSince ?? .distantPast) < ($1.doingSince ?? .distantPast) }
        let stats = ChildStats(all)
        List {
            Section {
                header(groups)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            if !doing.isEmpty {
                Section {
                    ForEach(doing) { item in
                        DoingCard(item: item)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    }
                } header: {
                    SectionLabel(title: "Nogitivity", tint: Theme.blue)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        AgendaRow(entry: entry, now: now, subItems: stats[entry.item.id])
                    }
                } header: {
                    SectionLabel(title: group.title, count: group.entries.count,
                                 tint: group.title == "Nogging now" ? Theme.pink : Theme.muted)
                }
                .listRowBackground(Theme.glass)
            }
            if groups.isEmpty && doing.isEmpty {
                Section {
                    ContentUnavailableView("Nothing timed this week",
                                           systemImage: "calendar",
                                           description: Text("Things with a time show up here. Untimed ones wait on the Nogs tab."))
                        .listRowBackground(Color.clear)
                }
            }
        }
        .nogListStyle()
    }

    private func header(_ groups: [Agenda.Group]) -> some View {
        let nogging = groups.first { $0.title == "Nogging now" }?.entries.count ?? 0
        let today = groups.filter { $0.title == "Nogging now" || $0.title == "Later today" }
            .map(\.entries.count).reduce(0, +)
        return HStack(alignment: .lastTextBaseline) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                .font(.nogLabel)
                .tracking(2)
                .foregroundStyle(Theme.muted)
            Spacer()
            Text("\(nogging) nogging · \(today) today")
                .font(.nogMeta)
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 2)
    }
}

/// One timed thing: glowing time, title, a detail line, and whether it's a Nog or an Alarm.
private struct AgendaRow: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: Agenda.Entry
    let now: Date
    let subItems: (done: Int, total: Int)

    var body: some View {
        let item = entry.item
        let kind = NogKind.of(item.reminder)
        // At the accessibility text sizes the time sits above the title instead of in a column.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        NavigationLink(value: item.id) {
            layout {
                Text(timeText)
                    .nogReadout(13)
                    .foregroundStyle(entry.isNogging ? Theme.pink : (isToday ? Theme.lcd : Theme.muted))
                    .nogGlow(color: isToday && !entry.isNogging ? Theme.blue.opacity(0.5) : .clear, radius: 4)
                    .frame(width: typeSize.isAccessibilitySize ? nil : 66, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .nogLineLimit()
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .nogLineLimit()
                }
                Spacer(minLength: 6)
                KindBadge(kind: kind)
            }
        }
        .appEntityIdentifier(EntityIdentifier(for: ReminderEntity.self, identifier: item.id))
        .swipeActions(edge: .leading) {
            Button("Nogged") { store.markDone(item.id) }.tint(ProgressRing.complete)
        }
        .swipeActions(edge: .trailing) {
            let snooze = NogSettings.snoozeLength(for: item)
            Button {
                store.snooze(item.id, until: now.addingTimeInterval(TimeInterval(snooze * 60)))
            } label: {
                Label(NogSettings.snoozeLabel(minutes: snooze), systemImage: "zzz")
            }
            .tint(Theme.pink)
            Button {
                store.snooze(item.id, until: NogSettings.nextMorning(for: item, after: now))
            } label: {
                Label(NogSettings.morningSnoozeLabel(minutes: item.reminder?.morningMinutes ?? NogSettings.morningMinutes),
                      systemImage: "sunrise")
            }
            .tint(Theme.violet)
        }
        .accessibilityElement(children: .combine)
    }

    private var isToday: Bool { Calendar.current.isDate(entry.when, inSameDayAs: now) }

    /// "now" while nogging; a clock time today and tomorrow; a weekday later in the week.
    private var timeText: String {
        if entry.isNogging { return "now" }
        let calendar = Calendar.current
        if calendar.isDate(entry.when, inSameDayAs: now)
            || calendar.date(byAdding: .day, value: 1, to: now).map({ calendar.isDate(entry.when, inSameDayAs: $0) }) == true {
            return entry.when.formatted(date: .omitted, time: .shortened)
        }
        return entry.when.formatted(.dateTime.weekday(.abbreviated))
    }

    private var detail: String {
        let item = entry.item
        var parts: [String] = []
        if let r = item.reminder {
            if entry.isNogging {
                if r.repeatMinutes != nil, entry.when > now {
                    parts.append("next \(entry.when.formatted(date: .omitted, time: .shortened))")
                }
                if let every = r.repeatSummary { parts.append(every) }
            } else {
                let calendar = Calendar.current
                let soon = calendar.isDate(entry.when, inSameDayAs: now)
                    || calendar.date(byAdding: .day, value: 1, to: now).map({ calendar.isDate(entry.when, inSameDayAs: $0) }) == true
                if !soon { parts.append(entry.when.formatted(date: .omitted, time: .shortened)) }
                parts.append(r.repeatSummary.map { "then \($0)" } ?? "once")
            }
        }
        if subItems.total > 0 { parts.append("\(subItems.done)/\(subItems.total) sub-items") }
        if let tag = item.tags.first { parts.append("#\(tag)") }
        return parts.joined(separator: " · ")
    }
}
