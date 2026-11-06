import AppIntents
import SwiftUI

struct ItemDetailView: View {
    @Environment(ItemStore.self) private var store
    let id: UUID

    var body: some View {
        if let item = store.items[id] {
            ItemEditor(item: item)
        } else {
            ContentUnavailableView("Item deleted", systemImage: "trash")
        }
    }
}

private struct ItemEditor: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var tagsText: String
    @State private var newChild = ""
    @State private var showBreakdown = false
    @State private var showParentPicker = false
    @State private var confirmDelete = false

    init(item: Item) {
        self.item = item
        tagsText = item.tags.joined(separator: ", ")
    }

    /// Edits go straight to the store (and disk), so a "Done" tapped on a
    /// notification while this screen is open is never overwritten.
    private func binding<T>(_ keyPath: WritableKeyPath<Item, T>) -> Binding<T> {
        Binding(
            get: { store.items[item.id]?[keyPath: keyPath] ?? item[keyPath: keyPath] },
            set: { set(keyPath, $0) })
    }

    private func set<T>(_ keyPath: WritableKeyPath<Item, T>, _ value: T) {
        guard var current = store.items[item.id] else { return }
        current[keyPath: keyPath] = value
        store.update(current)
    }

    // MARK: Time helpers for the tuner

    static func minutesOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func setting(minutes: Int, on date: Date) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date) ?? date
    }

    static func combine(day: Date, timeOf time: Date) -> Date {
        setting(minutes: minutesOfDay(time), on: day)
    }

    /// The dial behaves like the matching buttons: Doing starts with the suggested
    /// timebox, Nogged marks it done, Open stops or reopens, Dream parks it.
    private func setStatus(_ new: ItemStatus) {
        guard new != item.status else { return }
        switch new {
        case .doing: store.start(item.id)
        case .done: store.markDone(item.id)
        case .open: item.isDoing ? store.stopDoing(item.id) : store.reopen(item.id)
        case .someday: set(\.status, .someday)
        }
    }

    private func editReminder(_ change: (inout Reminder) -> Void) {
        guard var current = store.items[item.id], var reminder = current.reminder else { return }
        change(&reminder)
        current.reminder = reminder
        store.update(current)
    }

    var body: some View {
        // Title → Start → Sub-items → Notes → Tags → Reminder → Status dial → the rest.
        Form {
            Section {
                TextField("Title", text: binding(\.title), axis: .vertical)
                    .font(.title3.weight(.semibold))
            }
            .listRowBackground(Theme.glass)

            doingSection

            childrenSection

            Section {
                TextEditor(text: binding(\.body))
                    .frame(minHeight: 140)
            } header: {
                SectionLabel(title: "Notes")
            } footer: {
                Text(verbatim: "Link to other items with [[Their title]].")
            }
            .listRowBackground(Theme.glass)

            GlassSection("Tags") {
                TextField("comma, separated", text: $tagsText)
                    .textInputAutocapitalization(.never)
                    .onChange(of: tagsText) {
                        set(\.tags, tagsText.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty })
                    }
            }

            reminderSection

            Section {
                VStack(spacing: 2) {
                    StatusDial(status: item.status) { setStatus($0) }
                    Text(StatusDial.summary(item.status))
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                SectionLabel(title: "Status")
            }
            .listRowBackground(Theme.glass)

            timeSection
            parentSection
            linksSection

            Section {
                Button("Delete", role: .destructive) { confirmDelete = true }
                    // Anchored to the button, so the confirmation pops up right here.
                    .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            store.delete(item.id)
                            dismiss()
                        }
                    } message: {
                        Text("“\(item.title)” and its notes will be removed. Sub-items stay, unfiled.")
                    }
            }
            .listRowBackground(Theme.glass)
        }
        .nogListStyle()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if item.status == .done {
                    Button {
                        store.reopen(item.id)
                    } label: {
                        Label("Reopen", systemImage: "arrow.uturn.backward.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(Theme.violet)
                } else {
                    Button {
                        store.markDone(item.id)
                    } label: {
                        Label("Done", systemImage: "checkmark.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(Theme.blue)
                }
            }
        }
        .sheet(isPresented: $showParentPicker) {
            ParentPicker(item: item)
        }
        .sheet(isPresented: $showBreakdown) {
            BreakdownSheet(item: item)
        }
        // iOS 27 on-screen awareness: "Siri, snooze this", "mark this done".
        .appEntityIdentifier(EntityIdentifier(for: ReminderEntity.self, identifier: item.id))
    }

    // MARK: Doing

    @ViewBuilder
    private var doingSection: some View {
        if item.isDoing {
            Section {
                DoingCard(item: item, showsTitle: false)
                    .listRowBackground(Color.clear)
                    // A little room so the section's rounded clip doesn't cut the card.
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            } header: {
                SectionLabel(title: "Nogitivity", tint: Theme.blue)
            }
        } else if item.status != .done {
            Section {
                StartButton(item: item, prominent: true)
                    // Room around the button so the section's rounded clip doesn't cut it.
                    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Tap to start with \(store.suggestedTimebox(for: item.id).label.lowercased()). Hold for other timeboxes.")
            }
        }
    }

    @ViewBuilder
    private var timeSection: some View {
        GlassSection("Time") {
            Picker("Estimate", selection: Binding(
                get: { item.estimateMinutes ?? 0 },
                set: { set(\.estimateMinutes, $0 > 0 ? $0 : nil) })) {
                Text("None").tag(0)
                ForEach(Array(Set(NogSettings.timeboxChoices + [item.estimateMinutes ?? 0])).filter { $0 > 0 }.sorted(),
                        id: \.self) { Text(IntervalFormat.amount($0)).tag($0) }
            }
            if item.totalTimeSpent() >= 60 {
                LabeledContent("Time spent", value: DurationFormat.short(item.totalTimeSpent()))
            }
            if let completed = item.completed {
                LabeledContent("Finished", value: completed.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    // MARK: Reminder

    private var reminderSection: some View {
        Section {
            Toggle("Nog me", isOn: Binding(
                get: { item.reminder != nil },
                set: { on in
                    set(\.reminder, on ? NogSettings.defaultReminderFromNow : nil)
                }))
            if let reminder = item.reminder {
                Menu {
                    ForEach(NogProfile.allCases) { profile in
                        Button {
                            editReminder { $0 = profile.apply(to: $0) }
                        } label: {
                            Label("\(profile.label): \(profile.summary)", systemImage: profile.systemImage)
                        }
                    }
                } label: {
                    HStack {
                        Text("Profile").foregroundStyle(.primary)
                        Spacer()
                        let current = NogProfile.matching(reminder)
                        Label(current?.label ?? "Custom", systemImage: current?.systemImage ?? "slider.horizontal.3")
                            .foregroundStyle(current == .relentless ? Theme.pink : Theme.violet)
                    }
                }
                // Day from a compact date picker, time from the tuner.
                DatePicker("Starts", selection: Binding(
                    get: { reminder.start },
                    set: { day in editReminder { $0.start = Self.combine(day: day, timeOf: $0.start) } }),
                    displayedComponents: .date)
                // Rolls across days (past midnight → tomorrow…), never earlier than now.
                TimeTuner(date: Binding(
                    get: { reminder.start },
                    set: { date in editReminder { $0.start = date } }),
                    title: "Starts at", notBefore: .now)
                    .padding(.vertical, 4)
                Picker("Repeat", selection: Binding(
                    get: { reminder.repeatMinutes ?? 0 },
                    set: { minutes in editReminder { $0.repeatMinutes = minutes > 0 ? minutes : nil } })) {
                    ForEach(repeatChoices(including: reminder.repeatMinutes ?? 0), id: \.self) {
                        Text(NogSettings.repeatLabel($0)).tag($0)
                    }
                }
                if reminder.repeatMinutes != nil {
                    Picker("Style", selection: Binding(
                        get: { reminder.curve },
                        set: { curve in editReminder { $0.curve = curve } })) {
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
                                    editReminder { $0.alarm = true }
                                }
                            }
                        } else {
                            editReminder { $0.alarm = false }
                        }
                    })) {
                    Label("Ring like an alarm", systemImage: "alarm.waves.left.and.right")
                }
                HStack {
                    Button("Snooze \(IntervalFormat.amount(NogSettings.snoozeMinutes))") {
                        store.snooze(item.id, until: .now.addingTimeInterval(TimeInterval(NogSettings.snoozeMinutes * 60)))
                    }
                        .buttonStyle(OutlineButtonStyle(tint: Theme.pink))
                    Button(NogSettings.morningLabel) { store.snooze(item.id, until: NogSettings.nextMorning()) }
                        .buttonStyle(OutlineButtonStyle(tint: Theme.violet))
                }
            }
        } header: {
            SectionLabel(title: "Reminder")
        } footer: {
            if item.isOpen, let reminder = item.reminder, let next = reminder.nextFire(after: .now) {
                Text("Next nog about \(next.formatted(date: .abbreviated, time: .shortened))"
                     + (reminder.repeatSummary.map { ", then \($0)." } ?? "."))
            } else if item.reminder != nil, !item.isOpen {
                Text("Paused: reminders only fire for open items.")
            }
        }
        .listRowBackground(Theme.glass)
        .tint(Theme.pink)
    }

    private func repeatChoices(including current: Int) -> [Int] {
        Array(Set(NogSettings.repeatChoices + [current])).sorted()
    }

    // MARK: Structure

    private var childrenSection: some View {
        let children = store.children(of: item.id)
        return GlassSection("Sub-items") {
            ForEach(children) { child in
                HStack {
                    Button {
                        if child.status == .done { store.reopen(child.id) } else { store.markDone(child.id) }
                    } label: {
                        Image(systemName: child.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(child.status == .done ? Theme.blue : Theme.muted)
                    }
                    .buttonStyle(.borderless)
                    NavigationLink(value: child.id) {
                        Text(child.title).strikethrough(child.status == .done)
                    }
                }
            }
            if ItemAssistant.isAvailable {
                Button {
                    showBreakdown = true
                } label: {
                    Label("Break it down", systemImage: "sparkles")
                }
            }
            TextField("Add sub-item…", text: $newChild)
                .submitLabel(.done)
                .onSubmit {
                    store.capture(newChild, parent: item.id)
                    newChild = ""
                }
        }
    }

    private var parentSection: some View {
        GlassSection("Part of") {
            if let parent = store.parent(of: item) {
                NavigationLink(value: parent.id) { Label(parent.title, systemImage: "arrow.up.circle") }
                Button("Detach from \(parent.title)") { set(\.parentID, nil) }
            }
            Button(item.parentID == nil ? "Put inside another item…" : "Move…") { showParentPicker = true }
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        let outgoing = item.outgoingLinkTitles
        let backlinks = store.backlinks(to: item)
        if !outgoing.isEmpty {
            GlassSection("Links") {
                ForEach(outgoing, id: \.self) { title in
                    if let target = store.resolve(title: title) {
                        NavigationLink(value: target.id) { Label(target.title, systemImage: "link") }
                    } else {
                        Button {
                            let created = store.createIdea(title: title)
                            router.push(created.id)
                        } label: {
                            Label("Create “\(title)”", systemImage: "plus")
                        }
                    }
                }
            }
        }
        if !backlinks.isEmpty {
            GlassSection("Linked from") {
                ForEach(backlinks) { source in
                    NavigationLink(value: source.id) { Label(source.title, systemImage: "arrow.uturn.left") }
                }
            }
        }
    }
}

private struct ParentPicker: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                let candidates = store.items.values
                    .filter { $0.id != item.id && !store.isDescendant($0.id, of: item.id) && $0.status != .done }
                    .filter { search.isEmpty || $0.title.lowercased().contains(search.lowercased()) }
                    .sorted { $0.updated > $1.updated }
                ForEach(candidates) { candidate in
                    Button(candidate.title) {
                        var updated = store.items[item.id] ?? item
                        updated.parentID = candidate.id
                        store.update(updated)
                        dismiss()
                    }
                }
            }
            .nogListStyle()
            .searchable(text: $search)
            .navigationTitle("Put inside…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// A Form/List section with a frosted row background and a HUD label.
struct GlassSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            SectionLabel(title: title)
        }
        .listRowBackground(Theme.glass)
    }
}
