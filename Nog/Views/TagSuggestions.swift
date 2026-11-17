import SwiftUI

/// A row of tappable tag suggestions, coloured like their Map zones.
/// Scrolls sideways when there are more than fit.
struct TagSuggestionStrip: View {
    /// "Recent" or "Tags"; shown as a small label before the chips.
    let title: String
    let tags: [String]
    let pick: (String) -> Void

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(.nogMicroLabel)
                        .tracking(1.6)
                        .foregroundStyle(Theme.muted)
                    ForEach(tags, id: \.self) { tag in
                        let color = TagPalette.tint(for: tag)
                        Button {
                            pick(tag)
                        } label: {
                            Text("#\(tag)")
                                .font(.subheadline)
                                .foregroundStyle(color)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .background(color.opacity(0.10), in: Capsule())
                                .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add tag \(tag)")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .transition(.opacity)
        }
    }
}

extension TagPalette {
    /// The tag's colour, ready to use (the same one its Map zone gets).
    static func tint(for tag: String) -> Color {
        let pair = color(for: tag)
        return Color(light: pair.light, dark: pair.dark)
    }
}

/// The tag menu, shared by New Nog's Tags chip and the Map's info card. Tapping the
/// label opens a plain menu, no keyboard: up to seven tags (the nog's own first, then
/// the most used), each with a tick when it's on; "New tag…" to name one; and
/// "More tags…" for the full list once there are more than seven.
struct TagMenu<MenuLabel: View>: View {
    /// The tags on the nog now.
    let applied: [String]
    /// Tags that can't be taken off here (in New Nog, the ones typed in the text).
    var fixed: Set<String> = []
    let add: (String) -> Void
    let remove: (String) -> Void
    @ViewBuilder let label: () -> MenuLabel
    @Environment(ItemStore.self) private var store
    @State private var naming = false
    @State private var newName = ""
    @State private var showingAll = false

    static var shown: Int { 7 }

    var body: some View {
        let all = allTags
        Menu {
            ForEach(all.prefix(Self.shown), id: \.self) { tag in
                toggle(tag)
            }
            Divider()
            Button {
                naming = true
            } label: {
                Label("New tag…", systemImage: "plus")
            }
            if all.count > Self.shown {
                Button {
                    showingAll = true
                } label: {
                    Label("More tags…", systemImage: "ellipsis")
                }
                .accessibilityLabel("More tags, \(all.count - Self.shown) more")
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
        .alert("New tag", isPresented: $naming) {
            TextField("Tag name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                add(newName)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Nogs with the same tag share a zone on the Map.")
        }
        .sheet(isPresented: $showingAll) {
            TagListSheet(tags: all, applied: applied, fixed: fixed, add: add, remove: remove)
        }
    }

    /// The nog's tags first, then every other tag, most used and most recent first.
    private var allTags: [String] {
        let others = TagSuggester.suggest("", from: TagSuggester.stats(store.items.values),
                                          excluding: Set(applied), limit: .max)
        return applied + others
    }

    private func isOn(_ tag: String) -> Bool {
        applied.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func toggle(_ tag: String) -> some View {
        Toggle(isOn: Binding(get: { isOn(tag) },
                             set: { $0 ? add(tag) : remove(tag) })) {
            Text("#\(tag)")
        }
        .disabled(fixed.contains(tag))
        .accessibilityLabel(fixed.contains(tag) ? "\(tag), typed in the text" : tag)
    }
}

/// Every tag, for when there are more than the menu shows. Tap a row to put the tag
/// on or take it off. The search field only brings up the keyboard when tapped, and
/// can make a new tag from what's typed.
private struct TagListSheet: View {
    let tags: [String]
    let applied: [String]
    let fixed: Set<String>
    let add: (String) -> Void
    let remove: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Local copy so ticks update straight away.
    @State private var on: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                let typed = Item.cleanTag(query)
                if !typed.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
                    Button {
                        add(typed)
                        on.insert(typed.lowercased())
                        query = ""
                    } label: {
                        Label("New tag #\(typed)", systemImage: "plus")
                    }
                }
                ForEach(matching, id: \.self) { tag in
                    let ticked = on.contains(tag.lowercased())
                    Button {
                        if ticked { remove(tag); on.remove(tag.lowercased()) }
                        else { add(tag); on.insert(tag.lowercased()) }
                    } label: {
                        HStack {
                            Text("#\(tag)")
                                .foregroundStyle(TagPalette.tint(for: tag))
                            Spacer()
                            if ticked {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.blue)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .disabled(fixed.contains(tag))
                    .accessibilityLabel(fixed.contains(tag) ? "\(tag), typed in the text" : tag)
                    .accessibilityAddTraits(ticked ? .isSelected : [])
                }
            }
            .searchable(text: $query, prompt: "Find or make a tag")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { on = Set(applied.map { $0.lowercased() }) }
    }

    private var matching: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.localizedCaseInsensitiveContains(q) }
    }
}
