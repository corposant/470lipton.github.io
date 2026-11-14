import SwiftUI

/// The Agenda: the week ahead as a planner. A strip of days on top, then a page per day
/// with the time in the left margin. Everything nogging now sits in one "now" slot at the
/// top of today. Only nogs with a time are here; the Table and Overview have the rest.
struct AgendaList: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.editMode) private var editMode
    let now: Date
    @Binding var selection: Set<UUID>
    @AppStorage(ListSort.key) private var sort: ListSort = .next
    @AppStorage(ListSort.reversedKey) private var reversed = false
    @AppStorage(ListSort.urgentFirstKey) private var urgentFirst = true

    private var listSelection: Binding<Set<UUID>>? {
        editMode?.wrappedValue.isEditing == true ? $selection : nil
    }

    var body: some View {
        let all = Array(store.items.values)
        let stats = ChildStats(all)
        let doing = all.filter(\.isDoing).sorted { ($0.doingSince ?? .distantPast) < ($1.doingSince ?? .distantPast) }
        let entries = Agenda.entries(all, now: now, policy: NogSettings.policy)
        let days = Agenda.days(entries, now: now) { items in
            sort.sorted(items, now: now, stats: stats, reversed: reversed, urgentFirst: urgentFirst)
        }

        ScrollViewReader { proxy in
            List(selection: listSelection) {
                DoingSection(items: doing)
                ForEach(days) { day in
                    Section {
                        ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                            let previous = index > 0 ? day.entries[index - 1] : nil
                            NogRow(item: entry.item, now: now, stats: stats, omit: [.when],
                                   margin: AgendaMargin(entry: entry, previous: previous, now: now))
                                .zebraRow(index)
                        }
                    } header: {
                        SectionLabel(title: Self.title(for: day.date, now: now), count: day.entries.count,
                                     tint: Calendar.current.isDate(day.date, inSameDayAs: now) ? Theme.pink : Theme.muted)
                    }
                }
            }
            .preference(key: SelectableNogsKey.self, value: Set(entries.map(\.id)))
            .nogListStyle()
            .overlay {
                if days.isEmpty && doing.isEmpty {
                    ContentUnavailableView("Nothing timed this week", systemImage: "calendar",
                                           description: Text("Nogs with a time show up here, day by day."))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                WeekStrip(days: days, now: now) { day in
                    guard let first = day.entries.first else { return }
                    withNogAnimation(.snappy) { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    /// "Today, Nov 12" · "Tomorrow, Nov 13" · "Saturday, Nov 14".
    static func title(for day: Date, now: Date, calendar: Calendar = .current) -> String {
        let date = day.formatted(.dateTime.month(.abbreviated).day())
        if calendar.isDate(day, inSameDayAs: now) { return "Today, \(date)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) {
            return "Tomorrow, \(date)"
        }
        return "\(day.formatted(.dateTime.weekday(.wide))), \(date)"
    }
}

/// The time in the Agenda's margin: "now", or a clock time. Left blank when it's the same
/// as the row above, like a planner.
struct AgendaMargin {
    let text: String
    let isNow: Bool
    let isToday: Bool

    init(entry: Agenda.Entry, previous: Agenda.Entry?, now: Date) {
        let text = Self.text(entry)
        let same = previous.map { Self.text($0) == text } ?? false
        self.text = same ? "" : text
        isNow = entry.isNogging
        isToday = Calendar.current.isDate(entry.when, inSameDayAs: now)
    }

    private static func text(_ entry: Agenda.Entry) -> String {
        entry.isNogging ? "now" : entry.when.formatted(date: .omitted, time: .shortened)
    }

    var label: some View {
        Text(text)
            .nogReadout(13)
            .foregroundStyle(isNow ? Theme.pink : (isToday ? Theme.lcd : Theme.muted))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            // The row reads its time from the detail line's place in VoiceOver; say it once, here.
            .accessibilityLabel(isNow ? "Nogging now" : text)
    }
}

/// Seven days from today. A dot marks a day with nogs; tap one to jump to its page.
private struct WeekStrip: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let days: [Agenda.Day]
    let now: Date
    let jump: (Agenda.Day) -> Void

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        Group {
            if typeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) { cells(dates, calendar: calendar, width: 76) }
                        .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            } else {
                HStack(spacing: 4) { cells(dates, calendar: calendar, width: nil) }
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func cells(_ dates: [Date], calendar: Calendar, width: CGFloat?) -> some View {
        ForEach(dates, id: \.self) { date in
            let day = days.first { calendar.isDate($0.date, inSameDayAs: date) }
            let count = day?.entries.count ?? 0
            let isToday = calendar.isDate(date, inSameDayAs: now)
            Button {
                if let day { jump(day) }
            } label: {
                VStack(spacing: 2) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    Text(date.formatted(.dateTime.day()))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Color.primary)
                    Circle()
                        .fill(count > 0 ? Theme.pink : Color.clear)
                        .frame(width: 5, height: 5)
                }
                .frame(minWidth: width, maxWidth: width == nil ? .infinity : width)
                .frame(minHeight: 52)
                .background {
                    if isToday {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.pink.opacity(0.16))
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.pink.opacity(0.5), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .accessibilityValue(count == 0 ? "No nogs" : "\(count) \(count == 1 ? "nog" : "nogs")")
            .accessibilityHint(count == 0 ? "" : "Jumps to that day")
        }
    }
}
