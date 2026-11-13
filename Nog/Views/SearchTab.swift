import SwiftUI

/// Search, as its own round button at the bottom beside the tab bar (iOS 26). Finds nogs
/// by title, notes or #tag, and shows them with the same rows as the List.
struct SearchTab: View {
    @Environment(Router.self) private var router
    @Environment(ItemStore.self) private var store
    @State private var query = ""

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.searchPath) {
            TimelineView(MinuteSchedule.forItems(store.items.values)) { context in
                SearchResults(query: query, now: context.date)
            }
            .background { NogBackground() }
            .nogTabTitle(.search)
            .toolbar { SettingsToolbarItem() }
            // A steps button here goes to the List tab's Outline, inside that nog.
            .environment(\.openSteps, OpenStepsAction { id in router.showSteps(store.chain(to: id)) })
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
        }
        .searchable(text: $query, prompt: "Titles, notes, #tags")
    }
}

private struct SearchResults: View {
    @Environment(ItemStore.self) private var store
    let query: String
    let now: Date

    var body: some View {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty {
            ContentUnavailableView("Search your nogs", systemImage: "magnifyingglass",
                                   description: Text("Type a word from a title or a note, or a #tag."))
        } else {
            let all = Array(store.items.values)
            let stats = ChildStats(all)
            let tag = text.hasPrefix("#") ? String(text.dropFirst()) : text
            let matches = all.filter {
                $0.title.lowercased().contains(text) || $0.body.lowercased().contains(text)
                    || $0.tags.contains { $0.lowercased().contains(tag) }
            }
            let open = matches.filter { $0.status != .done }.sorted { $0.updated > $1.updated }
            let done = matches.filter { $0.status == .done }
                .sorted { ($0.completed ?? $0.updated) > ($1.completed ?? $1.updated) }
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    section("Results", open, stats: stats)
                    section("Done", done, stats: stats)
                }
                .nogListStyle()
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Item], stats: ChildStats) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NogRow(item: item, now: now, stats: stats)
                        .zebraRow(index)
                }
            } header: {
                SectionLabel(title: title, count: items.count)
            }
        }
    }
}
