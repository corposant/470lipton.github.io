import SwiftUI

/// A column the Table can show. A phone fits two beside the title and the ▶︎, so you pick
/// which two (the ⋯ in the header); tapping a header sorts by it.
enum ListColumn: String, CaseIterable, Identifiable {
    case next = "Next"
    case repeats = "Repeats"
    case steps = "Steps"
    case tags = "Tags"
    case added = "Added"

    var id: String { rawValue }

    static let firstKey = "tableColumn1"
    static let secondKey = "tableColumn2"

    /// The sort a tap on this header picks, if it has one.
    var sort: ListSort? {
        switch self {
        case .next: .next
        case .steps: .steps
        case .added: .added
        case .repeats, .tags: nil
        }
    }

    /// The detail-line fact this column replaces.
    var fact: RowFact? {
        switch self {
        case .next: .when
        case .repeats: .repeats
        case .steps: .steps
        case .tags: .tags
        case .added: nil
        }
    }

    /// Width at the default text size; grows with text size like the ▶︎ does.
    var baseWidth: CGFloat {
        switch self {
        case .next: 62
        case .repeats: 64
        case .steps: 50
        case .tags: 66
        case .added: 56
        }
    }

    /// The cell's main line and an optional small second line.
    func lines(_ item: Item, now: Date, counts: (done: Int, total: Int)) -> (String, String?) {
        switch self {
        case .next:
            // One line: a time today, a weekday this week, a date after that.
            guard let date = item.nextDate(after: now) else { return ("–", nil) }
            if date <= now { return ("now", nil) }
            if Calendar.current.isDate(date, inSameDayAs: now) { return (date.formatted(date: .omitted, time: .shortened), nil) }
            if date.timeIntervalSince(now) < 6 * 86_400 { return (date.formatted(.dateTime.weekday(.abbreviated)), nil) }
            return (date.formatted(.dateTime.month(.abbreviated).day()), nil)
        case .repeats:
            if item.isOpen, let minutes = item.reminder?.repeatMinutes { return (IntervalFormat.short(minutes), nil) }
            if item.status != .done, let recurrence = item.recurrence { return (recurrence.summary, nil) }
            return ("–", nil)
        case .steps:
            return counts.total > 0 ? ("\(counts.done)/\(counts.total)", nil) : ("–", nil)
        case .tags:
            guard let first = item.tags.first else { return ("–", nil) }
            return ("#\(first)" + (item.tags.count > 1 ? " +\(item.tags.count - 1)" : ""), nil)
        case .added:
            return (item.created.formatted(.dateTime.month(.abbreviated).day()), nil)
        }
    }

    /// The cell in words, for VoiceOver and for the folded rows at large text sizes.
    func spoken(_ item: Item, now: Date, counts: (done: Int, total: Int)) -> String {
        switch self {
        case .next:
            guard let date = item.nextDate(after: now) else { return "none" }
            return date.formatted(.relative(presentation: .named))
        case .steps:
            return counts.total > 0 ? "\(counts.done) of \(counts.total) done" : "none"
        default:
            let (main, sub) = lines(item, now: now, counts: counts)
            if main == "–" { return "none" }
            return [main, sub].compactMap { $0 }.joined(separator: " ")
        }
    }
}

/// One Table cell. The Steps cell is the steps button: tap it to go inside in the Outline.
struct TableCell: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let column: ListColumn
    let item: Item
    let now: Date
    let counts: (done: Int, total: Int)
    let openSteps: () -> Void

    var body: some View {
        let lines = column.lines(item, now: now, counts: counts)
        let main = lines.0, sub = lines.1
        Group {
            if column == .steps && counts.total > 0 {
                Button(action: openSteps) {
                    Text(main)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.blue.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Theme.blue.opacity(0.4), lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Steps, \(counts.done) of \(counts.total) done")
                .accessibilityHint("Shows the steps inside \(item.title)")
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(main)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(main == "–" ? Theme.muted : Color.primary)
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
            }
        }
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
    @AppStorage(ListColumn.firstKey) private var first: ListColumn = .next
    @AppStorage(ListColumn.secondKey) private var second: ListColumn = .steps

    private var listSelection: Binding<Set<UUID>>? {
        editMode?.wrappedValue.isEditing == true ? $selection : nil
    }

    var body: some View {
        let all = Array(store.items.values)
        let stats = ChildStats(all)
        let doing = all.filter(\.isDoing).sorted { ($0.doingSince ?? .distantPast) < ($1.doingSince ?? .distantPast) }
        let listed = all.filter { $0.status == .open || $0.status == .someday || (showDone && $0.status == .done) }
        let rows = sort.sorted(listed, now: now, stats: stats, reversed: reversed, urgentFirst: urgentFirst)
        let columns = first == second ? [first] : [first, second]

        List(selection: listSelection) {
            DoingSection(items: doing)
            Section {
                TableHeader(columns: columns, first: $first, second: $second)
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
        .nogListStyle()
        .overlay {
            if rows.isEmpty && doing.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "tablecells",
                                       description: Text("Add one on the New Nog tab."))
            }
        }
    }
}

/// The Table's header row: tap a title to sort by it, again to reverse; ⋯ picks the columns.
/// It's a row in the list (not a section header) so it lines up with the rows exactly.
private struct TableHeader: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(ListSort.key) private var sort: ListSort = .next
    @AppStorage(ListSort.reversedKey) private var reversed = false
    let columns: [ListColumn]
    @Binding var first: ListColumn
    @Binding var second: ListColumn

    var body: some View {
        if typeSize.isAccessibilitySize {
            // Columns fold into the rows here; the header is just the column picker.
            columnMenu {
                Label("Columns", systemImage: "tablecells")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Color.clear.nogFrame(width: 28, height: 1)
                    header("Nog", sort: .name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(columns) { column in
                    header(column.rawValue, sort: column.sort)
                        .frame(width: NogScale.value(column.baseWidth, for: typeSize, maxScale: 1.6), alignment: .trailing)
                }
                columnMenu {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: TrailingSlot.width(typeSize), height: 44)
                }
            }
            .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private func header(_ title: String, sort target: ListSort?) -> some View {
        if let target {
            let isOn = sort == target
            Button {
                withNogAnimation(.snappy) {
                    if isOn { reversed.toggle() } else { sort = target; reversed = false }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(title.uppercased()).tracking(1)
                    if isOn {
                        Image(systemName: reversed ? "chevron.down" : "chevron.up").imageScale(.small)
                    }
                }
                .foregroundStyle(isOn ? Theme.blue : Theme.muted)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Sort by \(title)")
            .accessibilityValue(isOn ? (reversed ? "sorted, reversed" : "sorted") : "")
            .accessibilityAddTraits(isOn ? .isSelected : [])
        } else {
            Text(title.uppercased())
                .tracking(1)
                .foregroundStyle(Theme.muted)
                .frame(minHeight: 44)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func columnMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            Picker("First column", selection: $first) {
                ForEach(ListColumn.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Second column", selection: $second) {
                ForEach(ListColumn.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
        } label: {
            label()
        }
        .foregroundStyle(Theme.blue)
        .accessibilityLabel("Choose columns")
        .accessibilityValue(columns.map(\.rawValue).joined(separator: " and "))
    }
}
