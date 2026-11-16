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

/// The tag menu: the tags as chips (✕ takes one off), a field to type a new one, and
/// recent or matching tags to tap. Used by New Nog's Tags panel and the Map's info card,
/// so tagging looks and works the same in both places.
struct TagEditor<Focus: Hashable>: View {
    let tags: [String]
    /// Tags shown but not removable here (in New Nog, the ones typed in the text).
    var fixed: Set<String> = []
    @Binding var text: String
    let focus: FocusState<Focus>.Binding
    let focusValue: Focus
    let add: (String) -> Void
    let remove: (String) -> Void
    @Environment(ItemStore.self) private var store
    @ScaledMetric(relativeTo: .subheadline) private var fieldWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    chip(tag, removable: !fixed.contains(tag))
                }
                TextField("add tag", text: $text)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(focus, equals: focusValue)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .frame(width: fieldWidth).frame(minHeight: 32)
                    .padding(.horizontal, 10)
                    .overlay(Capsule().strokeBorder(Theme.edgeStrong, lineWidth: 1))
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Add tag")
                    .accessibilityHint("Type a tag, then press Done.")
            }
            TagSuggestionStrip(title: text.isEmpty ? "Recent" : "Tags",
                               tags: TagSuggester.suggest(text, from: TagSuggester.stats(store.items.values),
                                                          excluding: Set(tags))) { tag in
                add(tag)
                text = ""
            }
        }
    }

    private func submit() {
        add(text)
        text = ""
    }

    private func chip(_ tag: String, removable: Bool) -> some View {
        let color = TagPalette.tint(for: tag)
        return Button {
            if removable { remove(tag) }
        } label: {
            Text(removable ? "#\(tag) ✕" : "#\(tag)")
                .font(.subheadline)
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(color.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
                // A 44pt tall target around the 32pt capsule.
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!removable)
        .accessibilityLabel(removable ? "Remove tag \(tag)" : "Tag \(tag), typed in the text")
    }
}
