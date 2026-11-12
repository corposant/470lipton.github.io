import SwiftUI

/// Everything about how an item nogs you, in one sheet: how hard (profile), when,
/// repeat, alarm, and a plain-language preview of the next few nogs.
struct NogSheet: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Settings › "Ring as an alarm after": which profiles get the rings-through-Silent mark.
    @AppStorage(NogSettings.Key.escalateAfter) private var globalEscalate = 0
    let id: UUID
    @State private var showCalendar = false
    @State private var showKindHelp = false
    @State private var showFineTune = false

    private var item: Item? { store.items[id] }

    private func edit(_ change: (inout Reminder) -> Void) {
        guard var current = store.items[id], var reminder = current.reminder else { return }
        let before = reminder
        change(&reminder)
        // Giving a sub-item its own rhythm means it stops following its parent's.
        if current.parentID != nil, !reminder.sameRhythm(as: before) { reminder.followsParent = false }
        current.reminder = reminder
        store.update(current)
    }

    private func setOn(_ on: Bool) {
        guard var current = store.items[id] else { return }
        if on {
            var reminder = NogSettings.defaultReminderFromNow
            if let parent = parentReminder { reminder = reminder.takingRhythm(of: parent) }
            current.reminder = reminder
        } else {
            current.reminder = nil
        }
        store.update(current)
    }

    /// Note turns nogging off; Nog and Alarm turn it on (Alarm asks for permission to ring).
    private func setKind(_ kind: NogKind) {
        switch kind {
        case .note:
            setOn(false)
        case .nog:
            if store.items[id]?.reminder == nil { setOn(true) }
            edit { $0.alarm = false }
        case .alarm:
            if store.items[id]?.reminder == nil { setOn(true) }
            Task {
                if await AlarmScheduler.shared.requestAuthorization() {
                    edit { $0.alarm = true }
                }
            }
        }
    }

    /// The parent's reminder, when it passes its rhythm down.
    private var parentReminder: Reminder? {
        guard let item, let parent = store.parent(of: item), let r = parent.reminder, r.passesDown else { return nil }
        return r
    }

    private func setFollowsParent(_ on: Bool) {
        guard var current = store.items[id], var reminder = current.reminder else { return }
        reminder.followsParent = on
        if on, let parent = parentReminder { reminder = reminder.takingRhythm(of: parent) }
        current.reminder = reminder
        store.update(current)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let item {
                    // Note · Nog · Alarm, the same cards as on New Nog, with what will happen.
                    Section {
                        KindPicker(selected: NogKind.of(item.reminder)) { setKind($0) }
                        Text(NogKind.promise(for: item.reminder))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("What's the difference?") { showKindHelp = true }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                            .tint(Theme.violet)
                    } header: {
                        SectionLabel(title: "How")
                    }
                    .listRowBackground(Theme.glass)

                    placeSection(item)
                    if let reminder = item.reminder {
                        familySection(item, reminder)
                        profileSection(reminder)
                        whenSection(reminder)
                        comesBackSection(item, reminder)
                        snoozeSection(item, reminder)
                        previewSection(item, reminder)
                        fineTuneSection(item, reminder)
                    }
                }
            }
            .nogListStyle()
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.pink)
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showKindHelp) { NogKindSheet() }
    }

    // MARK: Parent and sub-items

    /// A sub-item can follow its parent's rhythm; a parent can pass its rhythm down.
    @ViewBuilder
    private func familySection(_ item: Item, _ reminder: Reminder) -> some View {
        let kids = store.children(of: item.id).filter { $0.status != .done && $0.reminder != nil }
        let parent = store.parent(of: item)
        if parentReminder != nil || !kids.isEmpty {
            Section {
                if let parent, parentReminder != nil {
                    Toggle(isOn: Binding(get: { reminder.followsParent }, set: setFollowsParent)) {
                        Label("Follow “\(parent.title)”", systemImage: "arrow.up.circle")
                    }
                }
                if !kids.isEmpty {
                    Toggle(isOn: Binding(
                        get: { reminder.passesDown },
                        set: { on in edit { $0.passesDown = on } })) {
                        Label("Sub-nogs nog the same way", systemImage: "arrow.down.circle")
                    }
                }
            } footer: {
                let following = kids.filter { $0.reminder?.followsParent == true }.count
                if !kids.isEmpty, reminder.passesDown {
                    Text("\(following) of \(kids.count) sub-nogs follow this.")
                } else if parentReminder != nil, reminder.followsParent {
                    Text("Changing anything here gives it its own rhythm.")
                }
            }
            .listRowBackground(Theme.glass)
            .tint(Theme.blue)
        }
    }

    // MARK: How hard

    private func profileSection(_ reminder: Reminder) -> some View {
        let current = NogProfile.matching(reminder)
        // Four across normally; two by two at the accessibility text sizes so names fit.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 2 : 4)
        return Section {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(NogProfile.allCases) { profile in
                    let isOn = profile == current
                    let tint = profile == .unhinged ? Theme.pink : Theme.violet
                    Button {
                        edit {
                            $0 = profile.apply(to: $0)
                            // Teatime moves the next reminder to tea time.
                            if profile.timeOfDay != nil { $0.start = profile.firstStart(from: .now) }
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: profile.systemImage)
                                .nogFont(15, weight: .semibold)
                                .breaksSilentBadge(profile.breaksSilent(globalEscalateAfter: globalEscalate))
                            Text(profile.label)
                                .font(.nogTitle(12))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
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
                    .accessibilityLabel(profile.spokenLabel(globalEscalateAfter: globalEscalate))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityHint(profile.summary)
                }
            }
        } header: {
            SectionLabel(title: "How firm")
        } footer: {
            Text(current?.summary ?? "Custom. Pick a style to reset.")
        }
        .listRowBackground(Color.clear)
        // Room from the row's rounded corners, which would otherwise clip the outer cards.
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .nogFeedback(.selection, trigger: current)
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
                    withNogAnimation(.snappy) { showCalendar.toggle() }
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
                .frame(minHeight: 32)
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

    // MARK: Where

    /// "When I get home": a saved place, arriving or leaving.
    private func placeSection(_ item: Item) -> some View {
        let places = PlaceBook.shared.places
        var names: [String] = places.map(\.name)
        if let p = item.place, !places.contains(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) {
            names.append(p.name)
        }
        return Section {
            Picker("Remind me at", selection: Binding<String?>(
                get: { item.place?.name },
                set: { name in
                    guard var current = store.items[id] else { return }
                    current.place = name.map { PlaceTrigger(name: $0, leaving: current.place?.leaving ?? false) }
                    store.update(current)
                })) {
                Text("No place").tag(String?.none)
                ForEach(names, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            if let place = item.place {
                Picker("When I", selection: Binding(
                    get: { place.leaving },
                    set: { leaving in
                        guard var current = store.items[id] else { return }
                        current.place?.leaving = leaving
                        store.update(current)
                    })) {
                    Text("Arrive").tag(false)
                    Text("Leave").tag(true)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            SectionLabel(title: "Where")
        } footer: {
            if places.isEmpty {
                Text("Save places in Settings › Places.")
            }
        }
        .listRowBackground(Theme.glass)
    }

    // MARK: Comes back

    /// A to-do that returns after it's done: meds every morning, bins every Tuesday.
    private func comesBackSection(_ item: Item, _ reminder: Reminder) -> some View {
        let choices = Recurrence.choices(for: reminder.start)
        let all = item.recurrence.map { current in choices.contains(current) ? choices : [current] + choices } ?? choices
        return Section {
            Picker("Comes back", selection: Binding<Recurrence?>(
                get: { item.recurrence },
                set: { new in
                    guard var current = store.items[id] else { return }
                    current.recurrence = new
                    if let new, var r = current.reminder {
                        r.start = new.aligned(r.start)
                        current.reminder = r
                    }
                    store.update(current)
                })) {
                Text("Never").tag(Recurrence?.none)
                ForEach(all, id: \.self) { Text($0.summary.prefix(1).uppercased() + $0.summary.dropFirst()).tag(Recurrence?.some($0)) }
            }
        } header: {
            SectionLabel(title: "Comes back")
        } footer: {
            Text("Done moves it to next time.")
        }
        .listRowBackground(Theme.glass)
    }

    // MARK: Fine-tune

    /// Exact gaps, style and snooze lengths: tucked away, since a style covers most needs.
    private func fineTuneSection(_ item: Item, _ reminder: Reminder) -> some View {
        let morningMinutes = reminder.morningMinutes ?? NogSettings.morningMinutes
        return Section {
            DisclosureGroup(isExpanded: $showFineTune) {
                rhythmRows(reminder)
                Picker("Snooze for", selection: Binding(
                    get: { reminder.snoozeMinutes ?? 0 },
                    set: { minutes in edit { $0.snoozeMinutes = minutes > 0 ? minutes : nil } })) {
                    Text("Default (\(IntervalFormat.amount(NogSettings.snoozeMinutes)))").tag(0)
                    ForEach(Array(Set(NogSettings.snoozeChoices + [reminder.snoozeMinutes ?? 5])).sorted(), id: \.self) {
                        Text(IntervalFormat.amount($0)).tag($0)
                    }
                }
                TimeTunerRow(title: "Morning snooze until", minutes: Binding(
                    get: { morningMinutes },
                    set: { minutes in
                        // Same as the default: follow the default (so changing it in Settings still applies).
                        edit { $0.morningMinutes = minutes == NogSettings.morningMinutes ? nil : minutes }
                    }))
            } label: {
                Text("Fine-tune")
            }
        }
        .listRowBackground(Theme.glass)
    }

    // MARK: Rhythm

    @ViewBuilder
    private func rhythmRows(_ reminder: Reminder) -> some View {
            Picker("Remind every", selection: Binding(
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
                    ForEach(RepeatCurve.customChoices(current: reminder.curve), id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
    }

    // MARK: Snooze

    /// The two snoozes, as actions you can take now, plus this item's own lengths for them.
    /// The same two buttons appear on its notifications (press and hold one).
    private func snoozeSection(_ item: Item, _ reminder: Reminder) -> some View {
        let snooze = NogSettings.snoozeLength(for: item)
        let morningMinutes = reminder.morningMinutes ?? NogSettings.morningMinutes
        let morning = NogSettings.nextMorning(for: item)
        let morningTitle = Calendar.current.isDateInTomorrow(morning)
            ? "Snooze till tomorrow \(morning.formatted(date: .omitted, time: .shortened))"
            : NogSettings.morningSnoozeLabel(minutes: morningMinutes)

        return Section {
            if item.isOpen {
                VStack(spacing: 8) {
                    Button {
                        store.snooze(id, until: .now.addingTimeInterval(TimeInterval(snooze * 60)))
                    } label: {
                        Label(NogSettings.snoozeLabel(minutes: snooze), systemImage: "zzz")
                    }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.pink))
                    Button {
                        store.snooze(id, until: morning)
                    } label: {
                        Label(morningTitle, systemImage: "sunrise")
                    }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.violet))
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
        } header: {
            SectionLabel(title: "Snooze")
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
            return "\(item.status.pausedReason)."
        }
        // Real arrival times: quiet hours push nogs to when they end, like the planner.
        let dates = policy.deliveryDates(for: reminder, after: now, limit: 4)
        guard let first = dates.first else { return "Already went off." }
        func show(_ date: Date) -> String {
            Calendar.current.isDateInToday(date)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        if dates.count == 1 { return "One nog at \(show(first))." }
        let rest = dates.dropFirst().map(show).joined(separator: ", ")
        return "First nog \(show(first)), then \(rest)… until it's done."
    }
}
