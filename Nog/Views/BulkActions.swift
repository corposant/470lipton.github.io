import SwiftUI

/// The bottom bar while selecting nogs: act on all of them at once.
struct BulkActionBar: View {
    @Environment(ItemStore.self) private var store
    @Binding var selection: Set<UUID>
    @State private var showAddTag = false
    @State private var confirmDelete = false

    private var selected: [Item] { selection.compactMap { store.items[$0] } }

    var body: some View {
        let none = selection.isEmpty
        HStack {
            Button {
                apply { $0.status = .done }
                selection = []
            } label: {
                Label("Nogged", systemImage: "checkmark.circle")
            }
            .disabled(none)

            Spacer()

            Menu {
                let open = selected.filter { $0.status != .done }
                Button {
                    store.batch {
                        for item in open {
                            store.snooze(item.id, until: .now.addingTimeInterval(TimeInterval(NogSettings.snoozeLength(for: item) * 60)))
                        }
                    }
                } label: {
                    Label("Snooze (each item's length)", systemImage: "zzz")
                }
                Button {
                    store.batch {
                        for item in open { store.snooze(item.id, until: NogSettings.nextMorning(for: item)) }
                    }
                } label: {
                    Label("Snooze till morning", systemImage: "sunrise")
                }
            } label: {
                Label("Snooze", systemImage: "zzz")
            }
            .disabled(none)

            Spacer()

            Menu {
                Section("Nog them") {
                    ForEach(NogProfile.allCases) { profile in
                        Button {
                            apply { item in
                                var r = item.reminder ?? NogSettings.defaultReminderFromNow
                                r = profile.apply(to: r)
                                // Picked for these items specifically: they stop following a parent.
                                if item.parentID != nil { r.followsParent = false }
                                item.reminder = r
                            }
                        } label: {
                            Label(profile.label, systemImage: profile.systemImage)
                        }
                    }
                    Button {
                        apply { $0.reminder = nil }
                    } label: {
                        Label("Stop nogging", systemImage: "bell.slash")
                    }
                }
                Section("Status") {
                    Button {
                        apply { $0.status = .open }
                    } label: {
                        Label("Open", systemImage: "circle")
                    }
                    Button {
                        apply { $0.status = .someday }
                    } label: {
                        Label("Move to Dream nogs", systemImage: "moon.stars")
                    }
                }
            } label: {
                Label("Nog", systemImage: "bell.badge")
            }
            .disabled(none)

            Spacer()

            Menu {
                Button {
                    showAddTag = true
                } label: {
                    Label("Add tag…", systemImage: "plus")
                }
                let tags = Array(Set(selected.flatMap { $0.tags.map { $0.lowercased() } })).sorted()
                if !tags.isEmpty {
                    Section("Remove") {
                        ForEach(tags, id: \.self) { tag in
                            Button(role: .destructive) {
                                apply { $0.removeTag(tag) }
                            } label: {
                                Label("#\(tag)", systemImage: "xmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Tags", systemImage: "number")
            }
            .disabled(none)

            Spacer()

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(none)
            .confirmationDialog("Delete \(selection.count) \(selection.count == 1 ? "item" : "items")?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    store.batch {
                        for id in selection { store.delete(id) }
                    }
                    selection = []
                }
            } message: {
                Text("Their notes go too. Sub-items of deleted items stay, unfiled.")
            }
        }
        .labelStyle(StackedLabelStyle())
        .sheet(isPresented: $showAddTag) {
            AddTagSheet { tag in
                apply { $0.addTag(tag) }
            }
        }
    }

    /// Changes every selected item, then reschedules nogs once.
    private func apply(_ change: (inout Item) -> Void) {
        store.batch {
            for id in selection {
                guard var item = store.items[id] else { continue }
                change(&item)
                store.update(item)
            }
        }
    }
}

/// Icon over a small caption, for the action bar.
private struct StackedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon.font(.system(size: 18, weight: .medium))
            configuration.title.font(.caption2.weight(.medium))
        }
        .frame(minWidth: 52, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Type a tag (with suggestions) to add to every selected item.
private struct AddTagSheet: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let add: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("tag", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { commit(text) }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .overlay(Capsule().strokeBorder(Theme.edgeStrong, lineWidth: 1))
                TagSuggestionStrip(title: text.isEmpty ? "Recent" : "Tags",
                                   tags: TagSuggester.suggest(text, from: TagSuggester.stats(store.items.values))) { tag in
                    commit(tag)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Add tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { commit(text) }
                        .disabled(Item.cleanTag(text).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(220)])
    }

    private func commit(_ tag: String) {
        guard !Item.cleanTag(tag).isEmpty else { return }
        add(tag)
        dismiss()
    }
}
