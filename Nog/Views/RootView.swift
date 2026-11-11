import AppIntents
import SwiftUI

/// The List tab (carton icon): everything, sorted by time; the week ahead, as a calendar
/// would show it; or an outline of what's inside what.
struct NogsTab: View {
    enum Mode: String, CaseIterable {
        case byTime = "By time", week = "Week", outline = "Outline"
    }

    @Environment(Router.self) private var router
    @Environment(ItemStore.self) private var store
    @State private var search = ""
    /// Which view of the list, remembered between launches.
    @AppStorage("listMode") private var mode: Mode = .byTime
    /// The outline shows finished items too when this is on.
    @AppStorage("outlineShowsDone") private var outlineShowsDone = false
    /// Select mode: tap rows to pick several, then act on them from the bottom bar.
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<UUID> = []

    private var isSelecting: Bool { editMode.isEditing }

    /// What "Select All" picks: everything listed except the finished pile.
    private var selectable: Set<UUID> {
        Set(store.items.values.filter { $0.status != .done }.map(\.id))
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            // Re-render each minute and as nogs start, so "in 5 min" / "nogging now" stay current.
            Group {
                // A search always lists matching items, whichever view you're on.
                if mode == .outline && search.isEmpty {
                    OutlineView(showNogged: outlineShowsDone)
                } else if mode == .week && search.isEmpty {
                    TimelineView(MinuteSchedule.forItems(store.items.values)) { context in
                        AgendaList(now: context.date)
                    }
                } else {
                    TimelineView(MinuteSchedule.forItems(store.items.values)) { context in
                        ItemListView(now: context.date, search: search, selection: $selection)
                    }
                }
            }
            .background { NogBackground() }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    SilenceBanner()
                    if !isSelecting {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                    }
                }
            }
            .nogTabTitle(.nogs, title: isSelecting ? (selection.isEmpty ? "Select nogs" : "\(selection.count) selected") : nil)
            // Search sits at the bottom, within thumb reach, leaving the top to the
            // By time / Week / Outline switch.
            .searchable(text: $search, placement: .toolbar, prompt: "Search")
            .environment(\.editMode, $editMode)
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        let all = selectable
                        Button(selection.isSuperset(of: all) && !all.isEmpty ? "Deselect All" : "Select All") {
                            selection = selection.isSuperset(of: all) ? [] : all
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { stopSelecting() }
                            .fontWeight(.semibold)
                    }
                } else {
                    if mode == .outline {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                outlineShowsDone.toggle()
                            } label: {
                                Image(systemName: outlineShowsDone ? "checkmark.circle.fill" : "checkmark.circle")
                            }
                            .accessibilityLabel(outlineShowsDone ? "Hide done items" : "Show done items")
                        }
                    } else if mode == .byTime {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Select") {
                                withNogAnimation(.snappy) { editMode = .active }
                            }
                        }
                    }
                    // Last, so it's always the top-right corner, as on every tab.
                    SettingsToolbarItem()
                }
            }
            // The tab bar makes way for the action bar while selecting, as in Mail and Photos.
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    BulkActionBar(selection: $selection)
                        .padding(.horizontal, 18)
                        .frame(height: 64)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.nog(.move(edge: .bottom).combined(with: .opacity)))
                }
            }
            .nogFeedback(.selection, trigger: selection.count)
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
        }
    }

    private func stopSelecting() {
        withNogAnimation(.snappy) {
            editMode = .inactive
            selection = []
        }
    }
}

struct ItemListView: View {
    @Environment(ItemStore.self) private var store
    let now: Date
    let search: String
    /// Rows picked in Select mode (the list only allows picking while editing).
    @Binding var selection: Set<UUID>
    @Environment(\.editMode) private var editMode

    /// Selection is only switched on in Select mode. A list that always has a selection
    /// treats a tap as "select this row", so rows wouldn't open.
    private var listSelection: Binding<Set<UUID>>? {
        editMode?.wrappedValue.isEditing == true ? $selection : nil
    }

    var body: some View {
        let all = Array(store.items.values)
        let stats = ChildStats(all)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if all.isEmpty {
            ContentUnavailableView("Nothing yet", systemImage: "tray",
                                   description: Text("Add one on the New Nog tab."))
        } else if !query.isEmpty {
            let results = all
                .filter { $0.title.lowercased().contains(query) || $0.body.lowercased().contains(query)
                    || $0.tags.contains { $0.lowercased().contains(query) } }
                .sorted { $0.updated > $1.updated }
            List(selection: listSelection) {
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
            let atPlace = open.filter { $0.reminder == nil && $0.place != nil }
                .sorted { $0.created < $1.created }
            let ideas = open.filter { $0.reminder == nil && $0.place == nil }
                .sorted { $0.updated > $1.updated }
            let someday = all.filter { $0.status == .someday }
                .sorted { $0.updated > $1.updated }
            let done = all.filter { $0.status == .done }
                .sorted { ($0.completed ?? $0.updated) > ($1.completed ?? $1.updated) }

            List(selection: listSelection) {
                if !doing.isEmpty {
                    Section {
                        ForEach(doing) { item in
                            DoingCard(item: item)
                                .appEntityIdentifier(EntityIdentifier(for: ReminderEntity.self, identifier: item.id))
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        }
                    } header: {
                        SectionLabel(title: "Doing", tint: Theme.blue)
                    }
                }
                section("Now", due, stats: stats)
                section("Later today", laterToday, stats: stats)
                section("Upcoming", onDeck, stats: stats)
                section("At a place", atPlace, stats: stats)
                section("No reminder", ideas, stats: stats)
                section("Someday", someday, stats: stats, dreamy: true)
                if !done.isEmpty {
                    Section {
                        DisclosureGroup {
                            ForEach(done.prefix(50)) { ItemRow(item: $0, now: now, stats: stats) }
                        } label: {
                            Text("\(done.count) finished").font(.nogMeta).foregroundStyle(Theme.muted)
                        }
                    } header: {
                        SectionLabel(title: "Done")
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
    @Environment(\.editMode) private var editMode
    let item: Item
    let now: Date
    var stats: ChildStats? = nil
    @State private var confirmDelete = false

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
            // While selecting, the row is just something to pick.
            if editMode?.wrappedValue.isEditing != true, item.status == .open || item.status == .someday {
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
        // No full swipe here: a long swipe shouldn't delete anything by accident.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Not role: .destructive, which would slide the row away before you've confirmed.
            Button {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            if item.status == .open || item.status == .someday {
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
            } else if item.isDoing {
                Button("+10 min") { store.extend(item.id, minutes: 10) }.tint(Theme.pink)
            }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(item.id) }
        } message: {
            Text("Its notes go too. Sub-nogs stay.")
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
            Image(systemName: item.place != nil && item.isOpen ? "location" : "lightbulb")
                .foregroundStyle(item.place != nil && item.isOpen ? Theme.violet : Theme.muted)
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
        if let recurrence = item.recurrence, item.status != .done { parts.append("repeats \(recurrence.summary)") }
        if let place = item.place, item.isOpen {
            parts.append(place.phrase + (PlaceBook.place(named: place.name) == nil ? " (place not set up)" : ""))
        }
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
            parts.append("\(counts.done)/\(childCount) sub-nogs")
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
            return "Once, \(when)"
        }
        if r.repeatMinutes != nil, let next = r.nextFire(after: now) {
            return "Next \(next.formatted(.relative(presentation: .named)))" + (r.silent ? " · silent" : "")
        }
        return "Went off \(r.start.formatted(.relative(presentation: .named)))"
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
