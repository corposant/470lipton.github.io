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
    @State private var showParentPicker = false
    @State private var confirmDelete = false

    init(item: Item) {
        self.item = item
        _tagsText = State(initialValue: item.tags.joined(separator: ", "))
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

    private func editReminder(_ change: (inout Reminder) -> Void) {
        guard var current = store.items[item.id], var reminder = current.reminder else { return }
        change(&reminder)
        current.reminder = reminder
        store.update(current)
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: binding(\.title), axis: .vertical)
                    .font(.title3.weight(.semibold))
                Picker("Status", selection: binding(\.status)) {
                    ForEach(ItemStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            reminderSection

            Section {
                TextEditor(text: binding(\.body))
                    .frame(minHeight: 140)
            } header: {
                Text("Notes")
            } footer: {
                Text(verbatim: "Link to other items with [[Their title]].")
            }

            Section("Tags") {
                TextField("comma, separated", text: $tagsText)
                    .textInputAutocapitalization(.never)
                    .onChange(of: tagsText) {
                        set(\.tags, tagsText.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty })
                    }
            }

            childrenSection
            parentSection
            linksSection

            Section {
                Button("Delete", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(item.id)
                dismiss()
            }
        }
        .sheet(isPresented: $showParentPicker) {
            ParentPicker(item: item)
        }
    }

    // MARK: Reminder

    private var reminderSection: some View {
        Section {
            Toggle("Nag me", isOn: Binding(
                get: { item.reminder != nil },
                set: { on in
                    set(\.reminder, on
                        ? Reminder(start: .now.addingTimeInterval(TimeInterval(NagSettings.firstDelayMinutes * 60)),
                                   repeatMinutes: NagSettings.repeatMinutes)
                        : nil)
                }))
            if let reminder = item.reminder {
                DatePicker("Starts", selection: Binding(
                    get: { reminder.start },
                    set: { date in editReminder { $0.start = date } }))
                Picker("Repeat", selection: Binding(
                    get: { reminder.repeatMinutes ?? 0 },
                    set: { minutes in editReminder { $0.repeatMinutes = minutes > 0 ? minutes : nil } })) {
                    ForEach(repeatChoices(including: reminder.repeatMinutes ?? 0), id: \.self) {
                        Text(NagSettings.repeatLabel($0)).tag($0)
                    }
                }
                HStack {
                    Button("Snooze 1h") { store.snooze(item.id, until: .now.addingTimeInterval(3600)) }
                    Spacer()
                    Button("Tomorrow 9 AM") { store.snooze(item.id, until: NagSettings.nextMorning()) }
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Reminder")
        } footer: {
            if item.isOpen, let next = item.reminder?.nextFire(after: .now) {
                Text("Next nag about \(next.formatted(date: .omitted, time: .shortened)).")
            } else if item.reminder != nil, !item.isOpen {
                Text("Paused: reminders only fire for open items.")
            }
        }
    }

    private func repeatChoices(including current: Int) -> [Int] {
        Array(Set(NagSettings.repeatChoices + [current])).sorted()
    }

    // MARK: Structure

    private var childrenSection: some View {
        let children = store.children(of: item.id)
        return Section("Sub-items") {
            ForEach(children) { child in
                HStack {
                    Button {
                        if child.status == .done { store.reopen(child.id) } else { store.markDone(child.id) }
                    } label: {
                        Image(systemName: child.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(child.status == .done ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    NavigationLink(value: child.id) {
                        Text(child.title).strikethrough(child.status == .done)
                    }
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
        Section("Part of") {
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
            Section("Links") {
                ForEach(outgoing, id: \.self) { title in
                    if let target = store.resolve(title: title) {
                        NavigationLink(value: target.id) { Label(target.title, systemImage: "link") }
                    } else {
                        Button {
                            let created = store.createIdea(title: title)
                            router.path.append(created.id)
                        } label: {
                            Label("Create “\(title)”", systemImage: "plus")
                        }
                    }
                }
            }
        }
        if !backlinks.isEmpty {
            Section("Linked from") {
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
            .searchable(text: $search)
            .navigationTitle("Put inside…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
