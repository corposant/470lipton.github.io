import AppIntents
import SwiftUI

// The List tab's shared language. Table, Agenda and Overview (and Search) all draw the
// same one-line row, NogRow:
//
//   [folder ring | Note · Nog · Alarm]  Title          [steps "4 ›"] [profile icon]
//
// with the same swipes (Start is a swipe right), the same Select mode and the same Sort
// menu. A chevron only ever means "go inside" (the steps button); tapping the row opens
// the nog. Everything the row leaves out is in its VoiceOver value.

/// The List tab's three views.
enum ListMode: String, CaseIterable, Identifiable {
    case table = "Table"
    case agenda = "Agenda"
    case overview = "Overview"

    var id: String { rawValue }

    static let key = "listMode"
}

/// Facts a view shows somewhere else (a Table column, the Agenda's time margin, the
/// nog's own page), so the row's detail line leaves them out.
enum RowFact: Hashable {
    case when, repeats, steps, parent, tags
}

/// One nog, the same in every view.
struct NogRow: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: Item
    let now: Date
    let stats: ChildStats
    /// Left out of the detail line because the view shows them elsewhere.
    var omit: Set<RowFact> = []
    /// Table columns, at the trailing edge before Start.
    var columns: [ListColumn] = []
    /// Agenda: the time in the left margin.
    var margin: AgendaMargin? = nil
    /// Overview: a project's next step, the one second line a row ever gets.
    var subtitle: AttributedString? = nil
    @State private var confirmDelete = false
    @AppStorage(NogSettings.Key.escalateAfter) private var globalEscalate = 0

    /// What the hidden detail line would have said, plus the alarm profile, for VoiceOver.
    private func spokenDetail(_ counts: (done: Int, total: Int)) -> String {
        var parts: [String] = []
        if item.isOpen, let r = item.reminder, let profile = NogProfile.matching(r) {
            parts.append(profile.spokenLabel(globalEscalateAfter: globalEscalate))
        }
        if let detail = RowDetail.text(item, now: now, counts: counts, store: store, omit: omit) {
            parts.append(String(detail.characters))
        }
        return parts.joined(separator: ", ")
    }

    private var canStart: Bool { item.status == .open || item.status == .someday }
    /// At the accessibility text sizes columns and the margin fold under the title.
    private var folded: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let counts = stats[item.id]
        HStack(spacing: 8) {
            NavigationLink(value: item.id) {
                HStack(spacing: 10) {
                    if let margin, !folded {
                        margin.label
                            .frame(width: NogScale.value(52, for: typeSize, maxScale: 1.6), alignment: .leading)
                    }
                    NogKindIcon(item: item, now: now, steps: counts)
                    VStack(alignment: .leading, spacing: 3) {
                        if let margin, folded, !margin.text.isEmpty { margin.label }
                        NogTitle(item: item)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        }
                        // One line: no detail line. At the accessibility text sizes the Table's
                        // columns can't fit beside the title, so only they fold underneath.
                        if folded, !columns.isEmpty,
                           let cells = RowDetail.text(item, now: now, counts: counts, store: store,
                                                      omit: [.when, .repeats, .steps, .parent, .tags], folded: columns) {
                            Text(cells).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationLinkIndicatorVisibility(.hidden)
            // The row shows only the title; VoiceOver still hears when it's next, its steps,
            // where it sits and its tags.
            .accessibilityValue(spokenDetail(counts))

            if !folded {
                ForEach(columns) { column in
                    TableCell(column: column, item: item, now: now, counts: counts)
                }
            }
            // The alarm profile, at the right end. Its slot is kept when there's none,
            // so the Table's columns line up. Start lives in the swipe and the nog's page.
            ProfileMark(item: item)
                .frame(width: TrailingSlot.width(typeSize))
        }
        // iOS 27: Siri can act on whichever row you're looking at.
        .appEntityIdentifier(EntityIdentifier(for: ReminderEntity.self, identifier: item.id))
        .swipeActions(edge: .leading) {
            if item.status == .done {
                Button("Reopen") { store.reopen(item.id) }.tint(Theme.violet)
            } else {
                Button("Complete") { store.markDone(item.id) }.tint(Theme.blue)
                if !item.isDoing {
                    Button("Start") { store.start(item.id) }.tint(Theme.violet)
                }
                Button {
                    store.setUrgent(item.id, !item.urgent)
                } label: {
                    Label(item.urgent ? "Not urgent" : "Urgent", systemImage: item.urgent ? "flag.slash" : "flag.fill")
                }
                .tint(Theme.pink)
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
            if canStart {
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
                Button("Done for now") { store.stopDoing(item.id) }.tint(Theme.violet)
            }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(item.id) }
        } message: {
            Text("Its notes go too. Sub-nogs stay.")
        }
    }
}

/// The width of a row's right end (the profile icon), and of the Table header's ⋯ above it.
enum TrailingSlot {
    static func width(_ typeSize: DynamicTypeSize) -> CGFloat {
        NogScale.value(44, for: typeSize, maxScale: 1.6)
    }
}

/// The title, with a pink "!" in front when it's urgent.
struct NogTitle: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: Item
    var font: Font = .body

    var body: some View {
        let done = item.status == .done
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if item.urgent && !done {
                Text("!")
                    .fontWeight(.heavy)
                    .foregroundStyle(Theme.pink)
                    .accessibilityLabel("Urgent")
            }
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .strikethrough(done)
                .foregroundStyle(done ? Theme.muted : Color.primary)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        }
        .font(font)
    }
}

/// What kind of nog this is, at a glance, on the left of every row: a folder in a ring for
/// one with steps (the ring is its progress), otherwise Note, Nog or Alarm, the same icons
/// as the New Nog picker. Done, doing and someday nogs show that instead.
struct NogKindIcon: View {
    let item: Item
    let now: Date
    let steps: (done: Int, total: Int)

    var body: some View {
        Group {
            if steps.total > 0 && item.status != .done {
                Image(systemName: "folder.fill")
                    .nogFont(11)
                    .foregroundStyle(Theme.blue)
                    .nogFrame(width: 28, height: 28)
                    .overlay {
                        ProgressRing(fraction: Double(steps.done) / Double(steps.total), lineWidth: 2)
                    }
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .nogFrame(width: 28, height: 28)
            }
        }
        // The row's VoiceOver value says all of this in words.
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch item.status {
        case .done: return "checkmark.circle"
        case .doing: return "play.circle"
        case .someday: return "moon.stars"
        case .open: return NogKind.of(item.reminder).systemImage
        }
    }

    private var tint: Color {
        switch item.status {
        case .done, .doing: return Theme.blue
        case .someday: return Theme.violet
        case .open:
            // Pink = nogging now, violet = coming up, grey = no reminder.
            if let r = item.reminder { return r.isActive(at: now) ? Theme.pink : Theme.violet }
            return item.place != nil ? Theme.violet : Theme.muted
        }
    }
}

/// The alarm profile's icon at a row's right end, with the rings-through-Silent mark when it
/// has one. Nothing for a note or a rhythm of its own. VoiceOver hears the profile in the
/// row's value instead.
struct ProfileMark: View {
    @AppStorage(NogSettings.Key.escalateAfter) private var globalEscalate = 0
    let item: Item

    var body: some View {
        if item.status != .done, let r = item.reminder, let profile = NogProfile.matching(r) {
            Image(systemName: profile.systemImage)
                .foregroundStyle(Theme.violet)
                .nogFrame(width: 28, height: 28)
                .breaksSilentBadge(profile.breaksSilent(globalEscalateAfter: globalEscalate))
                .accessibilityHidden(true)
        } else {
            Color.clear.nogFrame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }
}

/// The row's one detail line, built the same way in every view.
enum RowDetail {
    @MainActor
    static func text(_ item: Item, now: Date, counts: (done: Int, total: Int), store: ItemStore,
                     omit: Set<RowFact>, folded columns: [ListColumn] = []) -> AttributedString? {
        var parts: [AttributedString] = []
        func add(_ text: String) { parts.append(AttributedString(text)) }

        // Folded Table columns come first, labelled, in the order they'd sit on screen.
        for column in columns where column != .tags {
            add("\(column.rawValue) \(column.spoken(item, now: now, counts: counts))")
        }
        if item.isDoing {
            if let end = item.timeboxEnd {
                add(end > now ? "Doing · \(end.formatted(.relative(presentation: .named))) left" : "Doing · keep going")
            } else {
                add("Doing")
            }
        }
        if !omit.contains(.when), let when = whenText(item, now: now) { add(when) }
        if !omit.contains(.repeats), let repeats = repeatText(item) { add(repeats) }
        if let place = item.place, item.isOpen {
            add(place.phrase + (PlaceBook.place(named: place.name) == nil ? " (place not set up)" : ""))
        }
        if item.status == .someday { add("someday") }
        if !omit.contains(.steps), counts.total > 0 { add("\(counts.done)/\(counts.total) done") }
        if !omit.contains(.parent), let parent = store.parent(of: item) { add("in \(parent.title)") }
        if !omit.contains(.tags) || columns.contains(.tags), !item.tags.isEmpty {
            var tags = AttributedString()
            for (index, tag) in item.tags.enumerated() {
                if index > 0 { tags += AttributedString(" ") }
                var run = AttributedString("#\(tag)")
                let pair = TagPalette.color(for: tag)
                run.foregroundColor = Color(light: pair.light, dark: pair.dark)
                tags += run
            }
            parts.append(tags)
        }
        guard !parts.isEmpty else { return nil }
        var line = AttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { line += AttributedString(" · ") }
            line += part
        }
        return line
    }

    static func whenText(_ item: Item, now: Date) -> String? {
        if item.status == .done {
            return item.completed.map { "done \($0.formatted(.relative(presentation: .named)))" }
        }
        guard item.isOpen, let r = item.reminder else { return nil }
        if !r.isActive(at: now) { return "starts \(r.start.formatted(.relative(presentation: .named)))" }
        if r.repeatMinutes != nil, let next = r.nextFire(after: now) {
            return "next \(next.formatted(.relative(presentation: .named)))" + (r.silent ? " · silent" : "")
        }
        return "went off \(r.start.formatted(.relative(presentation: .named)))"
    }

    static func repeatText(_ item: Item) -> String? {
        if item.isOpen, let summary = item.reminder?.repeatSummary { return summary }
        if item.status != .done, let recurrence = item.recurrence { return "repeats \(recurrence.summary)" }
        return nil
    }
}

/// A faint violet tint on every other row, in place of divider lines, so the eye can
/// follow a row across. Stronger with Increase Contrast.
struct ZebraRowBackground: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let index: Int

    var body: some View {
        ZStack {
            Theme.glass
            if !index.isMultiple(of: 2) {
                Theme.violet.opacity(contrast == .increased ? 0.14 : 0.07)
            }
        }
    }
}

extension View {
    /// The List tab's row background: glass, tinted on every other row, no dividers.
    func zebraRow(_ index: Int) -> some View {
        listRowBackground(ZebraRowBackground(index: index))
            .listRowSeparator(.hidden)
            // One-line rows, close together; the ▶︎ and steps buttons keep 44 pt targets.
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
    }
}

/// Sort, reverse, urgent first, show done: one menu, the same in every view.
struct ListSortMenu: View {
    @AppStorage(ListSort.key) private var sort: ListSort = .next
    @AppStorage(ListSort.reversedKey) private var reversed = false
    @AppStorage(ListSort.urgentFirstKey) private var urgentFirst = true
    @AppStorage(ListSort.showDoneKey) private var showDone = false

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(ListSort.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Reverse order", isOn: $reversed)
            Toggle("Urgent first", isOn: $urgentFirst)
            Divider()
            Toggle("Show done", isOn: $showDone)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Sort and show")
        .accessibilityValue("Sorted by \(sort.rawValue)\(reversed ? ", reversed" : "")")
    }
}

/// The nogs you're working on, as timer cards, at the top of each view.
struct DoingSection: View {
    let items: [Item]

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    DoingCard(item: item)
                        .appEntityIdentifier(EntityIdentifier(for: ReminderEntity.self, identifier: item.id))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
            } header: {
                SectionLabel(title: "Doing", tint: Theme.blue)
            }
        }
    }
}
