import SwiftUI

struct RootView: View {
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
            .navigationTitle("Nog")
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
            .safeAreaInset(edge: .bottom) {
                CaptureBar()
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
        if all.isEmpty {
            ContentUnavailableView("Nothing captured yet",
                                   systemImage: "tray",
                                   description: Text("Type below and hit return. Everything nogs you until it's done."))
        } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = search.lowercased()
            let results = all
                .filter { $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
                    || $0.tags.contains { $0.lowercased().contains(q) } }
                .sorted { $0.updated > $1.updated }
            List {
                ForEach(results) { ItemRow(item: $0, now: now) }
            }
        } else {
            let open = all.filter(\.isOpen)
            let due = open.filter { $0.reminder?.isActive(at: now) == true }
                .sorted { $0.reminder!.start < $1.reminder!.start }
            let upcoming = open.filter { $0.reminder.map { !$0.isActive(at: now) } ?? false }
                .sorted { $0.reminder!.start < $1.reminder!.start }
            let ideas = open.filter { $0.reminder == nil }
                .sorted { $0.updated > $1.updated }
            let someday = all.filter { $0.status == .someday }
                .sorted { $0.updated > $1.updated }
            let done = all.filter { $0.status == .done }
                .sorted { ($0.completed ?? $0.updated) > ($1.completed ?? $1.updated) }

            List {
                section("Nogging now", due)
                section("Coming up", upcoming)
                section("No reminder", ideas)
                section("Someday", someday)
                if !done.isEmpty {
                    Section {
                        DisclosureGroup("Done (\(done.count))") {
                            ForEach(done.prefix(50)) { ItemRow(item: $0, now: now) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { ItemRow(item: $0, now: now) }
            }
        }
    }
}

struct ItemRow: View {
    @Environment(ItemStore.self) private var store
    let item: Item
    let now: Date

    var body: some View {
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
        .swipeActions(edge: .leading) {
            if item.status == .done {
                Button("Reopen") { store.reopen(item.id) }.tint(.blue)
            } else {
                Button("Done") { store.markDone(item.id) }.tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { store.delete(item.id) }
            Button("1 hour") { store.snooze(item.id, until: now.addingTimeInterval(3600)) }.tint(.orange)
            Button("Morning") { store.snooze(item.id, until: NogSettings.nextMorning(after: now)) }.tint(.indigo)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if item.status == .done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let r = item.reminder, item.isOpen {
            if r.isActive(at: now) {
                Image(systemName: "bell.badge.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "bell").foregroundStyle(.orange)
            }
        } else {
            Image(systemName: "lightbulb").foregroundStyle(.secondary)
        }
    }

    private var detailLine: some View {
        let childCount = store.children(of: item.id).count
        var parts: [String] = []
        if let text = reminderText { parts.append(text) }
        if childCount > 0 {
            let doneCount = store.children(of: item.id).filter { $0.status == .done }.count
            parts.append("\(doneCount)/\(childCount) sub-items")
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
            return "Reminds \(when)"
        }
        if r.repeatMinutes != nil, let next = r.nextFire(after: now) {
            return "Nogging until done · next \(next.formatted(.relative(presentation: .named)))"
                + (r.curve == .logarithmic ? " · easing off" : "")
        }
        return "Was due \(r.start.formatted(.relative(presentation: .named)))"
    }
}
