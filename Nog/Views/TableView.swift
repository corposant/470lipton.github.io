import SwiftUI

/// A Table column between the title and the alarm-profile icon. Each header is one of the
/// Sort menu's orders, so tapping it sorts by that.
enum ListColumn: String, CaseIterable, Identifiable {
    case priority = "Priority"
    case added = "Added"

    var id: String { rawValue }

    /// The sort a tap on this header picks.
    var sort: ListSort {
        switch self {
        case .priority: .priority
        case .added: .added
        }
    }

    /// Width at the default text size; grows with text size like the profile icon does.
    /// Wide enough for the header in capitals with its sort arrow.
    var baseWidth: CGFloat {
        switch self {
        case .priority: 70
        case .added: 60
        }
    }

    /// The cell's main line and an optional small second line.
    func lines(_ item: Item, now: Date, counts: (done: Int, total: Int)) -> (String, String?) {
        switch self {
        case .priority:
            return (item.urgent && item.status != .done ? "Urgent" : "–", nil)
        case .added:
            return (item.created.formatted(.dateTime.month(.abbreviated).day()), nil)
        }
    }

    /// The cell in words, for VoiceOver and for the folded rows at large text sizes.
    func spoken(_ item: Item, now: Date, counts: (done: Int, total: Int)) -> String {
        switch self {
        case .priority:
            return item.urgent && item.status != .done ? "urgent" : "not urgent"
        case .added:
            return item.created.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

/// One Table cell.
struct TableCell: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let column: ListColumn
    let item: Item
    let now: Date
    let counts: (done: Int, total: Int)

    var body: some View {
        let lines = column.lines(item, now: now, counts: counts)
        let main = lines.0, sub = lines.1
        VStack(alignment: .trailing, spacing: 1) {
            Text(main)
                .font(.caption.monospacedDigit())
                .foregroundStyle(main == "–" ? Theme.muted : (column == .priority ? Theme.pink : Color.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let sub {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.rawValue), \(column.spoken(item, now: now, counts: counts))")
        .frame(width: NogScale.value(column.baseWidth, for: typeSize, maxScale: 1.6), alignment: .trailing)
    }
}

/// The Table: every nog as a row, sorted by the column you tap.
struct NogTable: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.editMode) private var editMode
    let now: Date
    @Binding var selection: Set<UUID>
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
        let doing = all.filter(\.isDoing).sorted { ($0.doingSince ?? .distantPast) < ($1.doingSince ?? .distantPast) }
        let listed = all.filter { $0.status == .open || $0.status == .someday || (showDone && $0.status == .done) }
        let rows = sort.sorted(listed, now: now, stats: stats, reversed: reversed, urgentFirst: urgentFirst)
        let columns = ListColumn.allCases

        List(selection: listSelection) {
            DoingSection(items: doing)
            Section {
                TableHeader(columns: columns)
                    .listRowBackground(Theme.glass)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    // The same insets as the rows (zebraRow), so the columns line up.
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    NogRow(item: item, now: now, stats: stats, columns: columns)
                        .zebraRow(index)
                }
            } header: {
                SectionLabel(title: "All nogs", count: rows.count)
            }
        }
        .preference(key: SelectableNogsKey.self, value: Set(rows.map(\.id)))
        .fadeUnderTopBars()
        .nogListStyle()
        .overlay {
            if rows.isEmpty && doing.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "tablecells",
                                       description: Text("Add one on the New Nog tab."))
            }
        }
    }
}

/// The Table's header row: Nog, Priority, Added and the alarm-profile icon, each one of the
/// Sort menu's orders. Tap one to sort by it, again to reverse. It's a row in the list (not a
/// section header) so it lines up with the rows exactly.
private struct TableHeader: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(ListSort.key) private var sort: ListSort = .next
    @AppStorage(ListSort.reversedKey) private var reversed = false
    let columns: [ListColumn]

    var body: some View {
        if typeSize.isAccessibilitySize {
            // Columns fold into the rows here, so the headers wrap as plain sort buttons.
            ViewThatFits {
                HStack(spacing: 16) { buttons }
                VStack(alignment: .leading, spacing: 0) { buttons }
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Color.clear.nogFrame(width: 28, height: 1)
                    header(.name) { Text("NOG").tracking(1) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(columns) { column in
                    header(column.sort) { Text(column.rawValue.uppercased()).tracking(0.5) }
                        .frame(width: NogScale.value(column.baseWidth, for: typeSize, maxScale: 1.6), alignment: .trailing)
                }
                header(.alarms) { Image(systemName: "alarm") }
                    .frame(width: TrailingSlot.width(typeSize))
            }
            .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder private var buttons: some View {
        header(.name) { Text("Nog") }
        ForEach(columns) { column in header(column.sort) { Text(column.rawValue) } }
        header(.alarms) { Text("Alarm") }
    }

    private func header<Title: View>(_ target: ListSort, @ViewBuilder title: () -> Title) -> some View {
        let isOn = sort == target
        return Button {
            withNogAnimation(.snappy) {
                if isOn { reversed.toggle() } else { sort = target; reversed = false }
            }
        } label: {
            HStack(spacing: 2) {
                title()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
                if isOn {
                    Image(systemName: reversed ? "chevron.down" : "chevron.up")
                        .imageScale(.small)
                        .fixedSize()
                }
            }
            .foregroundStyle(isOn ? Theme.blue : Theme.muted)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Sort by \(target.label)")
        .accessibilityValue(isOn ? (reversed ? "sorted, reversed" : "sorted, \(target.spokenOrder)") : "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
