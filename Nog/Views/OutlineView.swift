import SwiftUI

/// The Outline: one level at a time, like an iPod menu. The top level lists the top nogs;
/// a nog's steps button ("4 ›") slides you inside it, where a summary card sits above its
/// steps. The path bar above takes you back up.
struct OutlineBrowser: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.editMode) private var editMode
    let now: Date
    @Binding var selection: Set<UUID>
    /// Where you are: the nog you're inside and the nogs around it, outermost first.
    let trail: [UUID]
    /// Goes up a level (the VoiceOver escape gesture).
    let back: () -> Void
    @AppStorage(ListSort.key) private var sort: ListSort = .next
    @AppStorage(ListSort.reversedKey) private var reversed = false
    @AppStorage(ListSort.urgentFirstKey) private var urgentFirst = true
    @AppStorage(ListSort.showDoneKey) private var showDone = false

    private var listSelection: Binding<Set<UUID>>? {
        editMode?.wrappedValue.isEditing == true ? $selection : nil
    }

    var body: some View {
        let all = Array(store.items.values)
        let stats = ChildStats(all)
        Group {
            if let id = trail.last, let parent = store.items[id] {
                inside(parent, stats: stats)
            } else {
                topLevel(all, stats: stats)
            }
        }
        .nogListStyle()
        .accessibilityAction(.escape) { if !trail.isEmpty { back() } }
    }

    private func topLevel(_ all: [Item], stats: ChildStats) -> some View {
        let doing = all.filter(\.isDoing).sorted { ($0.doingSince ?? .distantPast) < ($1.doingSince ?? .distantPast) }
        let visible = all.filter { $0.status == .open || $0.status == .someday || (showDone && $0.status == .done) }
        let tops = Item.outlineRoots(visible)
        let rows = sort.sorted(tops, now: now, stats: stats, reversed: reversed, urgentFirst: urgentFirst)
        return List(selection: listSelection) {
            DoingSection(items: doing)
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    NogRow(item: item, now: now, stats: stats)
                        .zebraRow(index)
                }
            } header: {
                SectionLabel(title: "All nogs", count: rows.count)
            }
        }
        .overlay {
            if rows.isEmpty && doing.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "list.bullet.indent",
                                       description: Text("Add one on the New Nog tab."))
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

/// "‹ All  ›  Address Roof": where you are in the Outline. Tap back to go up one level;
/// press and hold it to jump to any level above.
struct OutlinePathBar: View {
    @Environment(ItemStore.self) private var store
    let trail: [UUID]
    let go: ([UUID]) -> Void

    var body: some View {
        let titles = trail.map { store.items[$0].map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Gone" }
        let backTitle = trail.count >= 2 ? titles[trail.count - 2] : "All"
        HStack(spacing: 8) {
            Menu {
                Button("All nogs") { go([]) }
                ForEach(Array(trail.dropLast().enumerated()), id: \.offset) { index, _ in
                    Button(titles[index]) { go(Array(trail.prefix(index + 1))) }
                }
            } label: {
                Label(backTitle, systemImage: "chevron.backward")
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
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
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}
