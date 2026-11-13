import SwiftUI

/// The Overview's pages that aren't a nog.
enum OverviewPage {
    /// The "Loose nogs" page: every top-level nog without steps.
    static let looseID = UUID(uuidString: "00000000-0000-0000-0000-0000000100E5")!
}

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
/// urgent; tap one to filter), then one row per project with its next step, then all the
/// loose nogs folded into one row. Going into a project or Loose nogs slides like an iPod
/// menu; inside a project a summary card sits above its steps. The path bar takes you back.
struct OutlineBrowser: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.editMode) private var editMode
    let now: Date
    @Binding var selection: Set<UUID>
    /// Where you are: the nog you're inside and the nogs around it, outermost first.
    let trail: [UUID]
    /// Goes to a place in the Overview (Loose nogs).
    let open: ([UUID]) -> Void
    /// Goes up a level (the VoiceOver escape gesture).
    let back: () -> Void
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
        Group {
            if trail.last == OverviewPage.looseID {
                loose(all, stats: stats)
            } else if let id = trail.last, let parent = store.items[id] {
                inside(parent, stats: stats)
            } else {
                overview(all, stats: stats)
            }
        }
        // No backdrop of its own: the List tab's stays put behind, so a page sliding in or
        // out (or following a back swipe) doesn't drag a seam of background across the screen.
        .scrollContentBackground(.hidden)
        .accessibilityAction(.escape) { if !trail.isEmpty { back() } }
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
                        LooseRow(count: loose.count) { open([OverviewPage.looseID]) }
                            .zebraRow(0)
                            .selectionDisabled()
                    } header: {
                        SectionLabel(title: "Loose nogs")
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

    private func loose(_ all: [Item], stats: ChildStats) -> some View {
        let rows = roots(all, stats: stats).loose
        return List(selection: listSelection) {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    NogRow(item: item, now: now, stats: stats)
                        .zebraRow(index)
                }
            } header: {
                SectionLabel(title: "Loose nogs", count: rows.count)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No loose nogs", systemImage: "tray",
                                       description: Text("Every nog is part of a project."))
            }
        }
    }

    private func inside(_ parent: Item, stats: ChildStats) -> some View {
        // Steps keep the order you gave them (drag to reorder), finished ones included.
        let steps = store.children(of: parent.id)
        return List(selection: listSelection) {
            Section {
                OutlineSummary(item: parent, now: now, counts: stats[parent.id])
                    .listRowBackground(Theme.glass)
                    .selectionDisabled()
            }
            Section {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, item in
                    NogRow(item: item, now: now, stats: stats, omit: [.parent])
                        .zebraRow(index)
                }
                .onMove { source, destination in
                    store.moveChildren(of: parent.id, from: source, to: destination)
                }
            } header: {
                SectionLabel(title: "Steps", count: steps.count)
            }
        }
        .overlay {
            if steps.isEmpty {
                ContentUnavailableView("No steps yet", systemImage: "list.bullet.indent",
                                       description: Text("Open the nog and tap Break down, or add sub-nogs."))
            }
        }
    }
}

/// The card at the top of a level: the nog you're inside, its progress, and Start next step.
private struct OutlineSummary: View {
    @Environment(ItemStore.self) private var store
    let item: Item
    let now: Date
    let counts: (done: Int, total: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item.id) {
                HStack(spacing: 10) {
                    NogKindIcon(item: item, now: now, steps: counts)
                    VStack(alignment: .leading, spacing: 3) {
                        NogTitle(item: item, font: .title3.weight(.semibold))
                        if let detail = RowDetail.text(item, now: now, counts: (0, 0), store: store, omit: [.steps]) {
                            Text(detail).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Label("Details", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Theme.blue)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .navigationLinkIndicatorVisibility(.hidden)
            .accessibilityHint("Opens \(item.title)")

            if counts.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(counts.done), total: Double(counts.total))
                        .tint(Theme.blue)
                    Text("\(counts.done) of \(counts.total) steps done")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .accessibilityElement(children: .combine)
            }
            if item.status == .open || item.status == .someday {
                StartButton(item: item, prominent: true, subItems: counts.total > 0 ? counts : nil)
            }
        }
        .padding(.vertical, 6)
    }
}

/// "‹ Overview  ›  Address Roof": where you are in the Overview. Tap back to go up one level;
/// press and hold it to jump to any level above.
struct OutlinePathBar: View {
    @Environment(ItemStore.self) private var store
    let trail: [UUID]
    let go: ([UUID]) -> Void

    var body: some View {
        let titles = trail.map { id in
            id == OverviewPage.looseID ? "Loose nogs"
                : store.items[id].map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Gone"
        }
        let backTitle = trail.count >= 2 ? titles[trail.count - 2] : "Overview"
        HStack(spacing: 8) {
            Menu {
                Button("Overview") { go([]) }
                ForEach(Array(trail.dropLast().enumerated()), id: \.offset) { index, _ in
                    Button(titles[index]) { go(Array(trail.prefix(index + 1))) }
                }
            } label: {
                // Hugs its text; a long parent name truncates before the title does.
                Label(backTitle, systemImage: "chevron.backward")
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
            } primaryAction: {
                go(Array(trail.dropLast()))
            }
            .foregroundStyle(Theme.blue)
            .nogGlass(in: Capsule(), interactive: true)
            .accessibilityLabel("Back to \(backTitle)")
            .accessibilityHint("Hold to jump to any level above")

            Text(titles.last ?? "")
                .font(.headline)
                .lineLimit(2)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
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

/// The one row standing for every loose nog (no steps): tap it to go in.
private struct LooseRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full")
                    .foregroundStyle(Theme.violet)
                    .nogFrame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("Loose nogs")
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Text("\(count)").monospacedDigit()
                    Image(systemName: "chevron.forward").imageScale(.small)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.blue.opacity(0.14)))
                .overlay(Capsule().strokeBorder(Theme.blue.opacity(0.4), lineWidth: 1))
                Color.clear.frame(width: TrailingSlot.width(typeSize), height: 1)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Loose nogs, \(count)")
        .accessibilityHint("Shows the nogs that aren't part of a project")
    }
}
