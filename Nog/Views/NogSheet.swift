import SwiftUI

/// Everything about how an item nogs you, in one sheet: how hard (profile), when,
/// repeat, alarm, and a plain-language preview of the next few nogs.
struct NogSheet: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var showCalendar = false

    private var item: Item? { store.items[id] }

    private func edit(_ change: (inout Reminder) -> Void) {
        guard var current = store.items[id], var reminder = current.reminder else { return }
        change(&reminder)
        current.reminder = reminder
        store.update(current)
    }

    private func setOn(_ on: Bool) {
        guard var current = store.items[id] else { return }
        current.reminder = on ? NogSettings.defaultReminderFromNow : nil
        store.update(current)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let item {
                    Section {
                        Toggle("Nog until it's nogged", isOn: Binding(get: { item.reminder != nil }, set: setOn))
                    } footer: {
                        if item.reminder == nil {
                            Text("Turn on to get reminded, again and again, until you mark it nogged.")
                        }
                    }
                    .listRowBackground(Theme.glass)

                    if let reminder = item.reminder {
                        profileSection(reminder)
                        whenSection(reminder)
                        rhythmSection(reminder)
                        previewSection(item, reminder)
                    }
                }
            }
            .nogListStyle()
            .navigationTitle("Nog me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.pink)
        .presentationDragIndicator(.visible)
    }

    // MARK: How hard

    private func profileSection(_ reminder: Reminder) -> some View {
        let current = NogProfile.matching(reminder)
        return Section {
            HStack(spacing: 6) {
                ForEach(NogProfile.allCases) { profile in
                    let isOn = profile == current
                    let tint = profile == .relentless ? Theme.pink : Theme.violet
                    Button {
                        edit { $0 = profile.apply(to: $0) }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: profile.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                            Text(profile.label)
                                .font(.nogTitle(12))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(isOn ? tint : Color.primary.opacity(0.75))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(isOn ? tint.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isOn ? tint : Theme.edgeStrong, lineWidth: isOn ? 1.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    // Borderless: each card is its own tap target inside the row.
                    .buttonStyle(.borderless)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityHint(profile.summary)
                }
            }
        } header: {
            SectionLabel(title: "How hard")
        } footer: {
            Text(current?.summary ?? "Custom rhythm. Pick a profile to reset it.")
        }
        .listRowBackground(Color.clear)
        // Room from the row's rounded corners, which would otherwise clip the outer cards.
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .sensoryFeedback(.selection, trigger: current)
    }

    // MARK: When

    private func whenSection(_ reminder: Reminder) -> some View {
        let calendar = Calendar.current
        let start = reminder.start
        let hm = calendar.dateComponents([.hour, .minute], from: start)
        let isTonight = calendar.isDateInToday(start) && hm.hour == 20 && hm.minute == 0
        let isToday = calendar.isDateInToday(start) && !isTonight
        let isTomorrow = calendar.isDateInTomorrow(start)
        let tonightAvailable = (calendar.dateComponents([.hour], from: .now).hour ?? 0) < 20

        return Section {
            FlowLayout(spacing: 6) {
                dayChip("Today", isOn: isToday) {
                    edit { $0.start = Self.moving($0.start, toDay: .now) }
                }
                if tonightAvailable {
                    dayChip("Tonight", isOn: isTonight) {
                        edit { $0.start = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? $0.start }
                    }
                }
                dayChip("Tomorrow", isOn: isTomorrow) {
                    let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
                    edit { $0.start = Self.moving($0.start, toDay: tomorrow) }
                }
                dayChip("Pick…", isOn: showCalendar || (!isToday && !isTonight && !isTomorrow)) {
                    withAnimation(.snappy) { showCalendar.toggle() }
                }
            }
            if showCalendar {
                DatePicker("Day", selection: Binding(
                    get: { reminder.start },
                    set: { day in edit { $0.start = Self.moving($0.start, toDay: day) } }),
                    in: calendar.startOfDay(for: .now)...,
                    displayedComponents: .date)
                    .datePickerStyle(.graphical)
            }
            // Rolls across days (past midnight → tomorrow…), never earlier than now.
            TimeTuner(date: Binding(
                get: { reminder.start },
                set: { date in edit { $0.start = date } }),
                title: "Starts at", notBefore: .now)
                .padding(.vertical, 4)
        } header: {
            SectionLabel(title: "When")
        }
        .listRowBackground(Theme.glass)
    }

    private func dayChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(isOn ? Theme.blue : Color.primary.opacity(0.8))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(isOn ? Theme.blue.opacity(0.14) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Theme.blue : Theme.edgeStrong, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Same time of day on `day`; if that's already past, the next 5-minute mark.
    nonisolated static func moving(_ start: Date, toDay day: Date, now: Date = .now) -> Date {
        let calendar = Calendar.current
        let t = calendar.dateComponents([.hour, .minute], from: start)
        let moved = calendar.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: day) ?? day
        return moved > now ? moved : nextMark(after: now)
    }

    nonisolated static func nextMark(after now: Date) -> Date {
        let step: TimeInterval = 300
        return Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }

    // MARK: Rhythm

    private func rhythmSection(_ reminder: Reminder) -> some View {
        Section {
            Picker("Repeat", selection: Binding(
                get: { reminder.repeatMinutes ?? 0 },
                set: { minutes in edit { $0.repeatMinutes = minutes > 0 ? minutes : nil } })) {
                ForEach(Array(Set(NogSettings.repeatChoices + [reminder.repeatMinutes ?? 0])).sorted(), id: \.self) {
                    Text(NogSettings.repeatLabel($0)).tag($0)
                }
            }
            // Profiles set the curve; only a custom rhythm shows it.
            if reminder.repeatMinutes != nil, NogProfile.matching(reminder) == nil {
                Picker("Style", selection: Binding(
                    get: { reminder.curve },
                    set: { curve in edit { $0.curve = curve } })) {
                    ForEach(RepeatCurve.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Toggle(isOn: Binding(
                get: { reminder.alarm },
                set: { on in
                    if on {
                        Task {
                            if await AlarmScheduler.shared.requestAuthorization() {
                                edit { $0.alarm = true }
                            }
                        }
                    } else {
                        edit { $0.alarm = false }
                    }
                })) {
                Label("Ring like an alarm", systemImage: "alarm.waves.left.and.right")
            }
        } header: {
            SectionLabel(title: "Repeat")
        }
        .listRowBackground(Theme.glass)
    }

    // MARK: Preview

    private func previewSection(_ item: Item, _ reminder: Reminder) -> some View {
        Section {
            Text(Self.preview(item: item, reminder: reminder))
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
        .listRowBackground(Color.clear)
    }

    /// "First nog 3:40 PM, then 3:48 PM, 3:56 PM, 4:04 PM… until it's nogged." (after quiet hours)
    nonisolated static func preview(item: Item, reminder: Reminder, now: Date = .now,
                                    policy: NogPolicy = NogSettings.policy) -> String {
        guard item.isOpen else {
            return "\(item.status.pausedReason). Nogs pick up again when it's open."
        }
        // Real arrival times: quiet hours push nogs to when they end, like the planner.
        let dates = policy.deliveryDates(for: reminder, after: now, limit: 4)
        guard let first = dates.first else { return "Already went off. Snooze it or pick a new time." }
        func show(_ date: Date) -> String {
            Calendar.current.isDateInToday(date)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        if dates.count == 1 { return "One nog at \(show(first)), no repeat." }
        let rest = dates.dropFirst().map(show).joined(separator: ", ")
        return "First nog \(show(first)), then \(rest)… until it's nogged."
    }
}
