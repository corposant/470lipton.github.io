import SwiftUI

/// What the Overview's count tiles filter to.
enum OverviewFilter: String, CaseIterable, Identifiable {
    case now = "Now", today = "Today", urgent = "Urgent"
    var id: String { rawValue }

    var spoken: String {
        switch self {
        case .now: "Nogging now"
        case .today: "Due later today"
        case .urgent: "Urgent"
        }
    }

    var tint: Color {
        switch self {
        case .now, .urgent: Theme.pink
        case .today: Theme.violet
        }
    }

    func matches(_ item: Item, now: Date) -> Bool {
        guard item.isOpen || item.isDoing else { return false }
        switch self {
        case .now:
            return item.reminder?.isActive(at: now) == true
        case .today:
            guard let r = item.reminder, !r.isActive(at: now) else { return false }
            return Calendar.current.isDate(r.start, inSameDayAs: now)
        case .urgent:
            return item.urgent
        }
    }
}

/// The Overview: "where am I with everything". Counts on top (nogging now, due today,
/// urgent; tap one to filter), then one row per project with its next step, then the loose
/// nogs. A row opens the nog's own page, which has its steps.
struct OverviewList: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.editMode) private var editMode
    let now: Date
    @Binding var selection: Set<UUID>
    @AppStorage(ListSort.key) private var sort: ListSort = .next
    @AppStorage(ListSort.reversedKey) private var reversed = false
    @AppStorage(ListSort.urgentFirstKey) private var urgentFirst = true
    @AppStorage(ListSort.showDoneKey) private var showDone = false
    @State private var filter: OverviewFilter?

    private var listSelection: Binding<Set<UUID>>? {
        editMode?.wrappedValue.isEditing == true ? $selection : nil
    }

    var body: some View {
        let all = Array(store.items.values)
        let stats = ChildStats(all)
        overview(all, stats: stats)
            .nogListStyle()
    }

    private func sorted(_ items: [Item], stats: ChildStats) -> [Item] {
        sort.sorted(items, now: now, stats: stats, reversed: reversed, urgentFirst: urgentFirst)
    }

    /// Top-level nogs, split into projects (with steps) and loose ones.
    private func roots(_ all: [Item], stats: ChildStats) -> (projects: [Item], loose: [Item]) {
        let visible = all.filter { $0.status == .open || $0.status == .someday || (showDone && $0.status == .done) }
        let tops = Item.outlineRoots(visible)
        return (sorted(tops.filter { stats[$0.id].total > 0 }, stats: stats),
                sorted(tops.filter { stats[$0.id].total == 0 }, stats: stats))
    }

    private func overview(_ all: [Item], stats: ChildStats) -> some View {
        let doing = all.filter(\.isDoing).sorted { ($0.doingSince ?? .distantPast) < ($1.doingSince ?? .distantPast) }
        let (projects, loose) = roots(all, stats: stats)
        let counts = Dictionary(uniqueKeysWithValues: OverviewFilter.allCases.map { f in
            (f, all.filter { f.matches($0, now: now) }.count)
        })
        let filtered = filter.map { f in sorted(all.filter { f.matches($0, now: now) }, stats: stats) } ?? []
        return List(selection: listSelection) {
            Section {
                CountTiles(counts: counts, selected: $filter)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .selectionDisabled()
            }
            DoingSection(items: doing)
            if let filter {
                Section {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        NogRow(item: item, now: now, stats: stats)
                            .zebraRow(index)
                    }
                } header: {
                    SectionLabel(title: filter.spoken, count: filtered.count, tint: filter.tint)
                }
            } else {
                if !projects.isEmpty {
                    Section {
                        ForEach(Array(projects.enumerated()), id: \.element.id) { index, item in
                            NogRow(item: item, now: now, stats: stats, subtitle: nextStep(for: item))
                                .zebraRow(index)
                        }
                    } header: {
                        SectionLabel(title: "Projects", count: projects.count)
                    }
                }
                if !loose.isEmpty {
                    Section {
                        ForEach(Array(loose.enumerated()), id: \.element.id) { index, item in
                            NogRow(item: item, now: now, stats: stats)
                                .zebraRow(index)
                        }
                    } header: {
                        SectionLabel(title: "Loose nogs", count: loose.count)
                    }
                }
            }
        }
        .overlay {
            if projects.isEmpty && loose.isEmpty && doing.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "square.grid.2x2",
                                       description: Text("Add one on the New Nog tab."))
            } else if filter != nil && filtered.isEmpty {
                ContentUnavailableView("Nothing here right now", systemImage: "checkmark.circle",
                                       description: Text("Tap the count again to see everything."))
            }
        }
    }

    /// "next step · Check for structural damage": what Start next step would start.
    private func nextStep(for item: Item) -> AttributedString? {
        let target = store.startTarget(for: item.id)
        guard target != item.id, let step = store.items[target] else { return nil }
        var line = AttributedString("next step · ")
        var title = AttributedString(step.title.isEmpty ? "Untitled" : step.title)
        title.foregroundColor = Theme.lcd
        line += title
        return line
    }
}

/// Now · Today · Urgent. Tap one to show only those nogs; tap it again for everything.
private struct CountTiles: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let counts: [OverviewFilter: Int]
    @Binding var selected: OverviewFilter?

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            ForEach(OverviewFilter.allCases) { filter in
                let count = counts[filter] ?? 0
                let isOn = selected == filter
                Button {
                    withNogAnimation(.snappy) { selected = isOn ? nil : filter }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(filter.rawValue.uppercased())
                        } icon: {
                            if filter == .urgent { Image(systemName: "flag.fill") }
                        }
                        .labelStyle(.titleAndIcon)
                        .font(.nogLabel)
                        .tracking(1.6)
                        .foregroundStyle(filter.tint)
                        Text("\(count)")
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.primary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isOn ? filter.tint.opacity(0.18) : Theme.glass)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isOn ? filter.tint.opacity(0.6) : Theme.edge, lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                // Borderless, so each tile takes its own taps inside the list row.
                .buttonStyle(.borderless)
                .accessibilityLabel("\(filter.spoken), \(count)")
                .accessibilityHint(isOn ? "Shows everything again" : "Shows only these")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
