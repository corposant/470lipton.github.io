import AppIntents
import SwiftUI

/// The List tab (carton icon): a sortable Table, a week-planner Agenda, or an Overview of
/// projects and loose nogs. All three share one toolbar (Select, Sort, Settings),
/// one row (NogRow), one set of swipes and one Select mode. Search is its own tab.
struct NogsTab: View {
    @Environment(Router.self) private var router
    @Environment(ItemStore.self) private var store
    /// Which view of the list, remembered between launches.
    @AppStorage(ListMode.key) private var mode: ListMode = .table
    /// Select mode: tap rows to pick several, then act on them from the bottom bar.
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<UUID> = []

    private var isSelecting: Bool { editMode.isEditing }

    /// Published by the active list, after that view applies its filters.
    @State private var selectable: Set<UUID> = []

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            // Re-render each minute and as nogs start, so "in 5 min" / "nogging now" stay current.
            TimelineView(MinuteSchedule.forItems(store.items.values)) { context in
                content(now: context.date)
            }
            .background { NogBackground() }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    SilenceBanner()
                    if !isSelecting {
                        Picker("View", selection: $mode) {
                            ForEach(ListMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 4)
            }
            .nogTabTitle(.nogs, title: isSelecting ? (selection.isEmpty ? "Select nogs" : "\(selection.count) selected") : nil)
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
                    // The same three in every view, sharing one glass capsule.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Select") {
                            withNogAnimation(.snappy) { editMode = .active }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { ListSortMenu() }
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
                        .frame(minHeight: 64)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.nog(.move(edge: .bottom).combined(with: .opacity)))
                }
            }
            .onPreferenceChange(SelectableNogsKey.self) { ids in
                selectable = ids
                selection.formIntersection(ids)
            }
            .nogFeedback(.selection, trigger: selection.count)
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch mode {
        case .table:
            NogTable(now: now, selection: $selection)
        case .agenda:
            AgendaList(now: now, selection: $selection)
        case .overview:
            OverviewList(now: now, selection: $selection)
        }
    }

    private func stopSelecting() {
        withNogAnimation(.snappy) {
            editMode = .inactive
            selection = []
        }
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


/// Stable IDs of rows eligible for selection in the current list, not the whole store.
struct SelectableNogsKey: PreferenceKey {
    static var defaultValue: Set<UUID> { [] }
    static func reduce(value: inout Set<UUID>, nextValue: () -> Set<UUID>) {
        value.formUnion(nextValue())
    }
}
