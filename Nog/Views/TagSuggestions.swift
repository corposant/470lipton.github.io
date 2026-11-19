import SwiftUI

extension TagPalette {
    /// The tag's colour, ready to use (the same one its Map zone gets).
    static func tint(for tag: String) -> Color {
        let pair = color(for: tag)
        return Color(light: pair.light, dark: pair.dark)
    }
}

/// The tag menu: New Nog's Tags chip, the Map's info card, a nog's page and the List's
/// select bar all use it. A drawer (see `DrawerButton`) of tags: the nog's own first,
/// ticked, then the most used. Tap a tag to put it on (or take it off) and the drawer
/// closes. "New…" turns into a field in place (the only time the keyboard comes up);
/// "More…" shows every tag once there are more than seven.
struct TagMenu<MenuLabel: View>: View {
    /// The tags on the nog now (with several nogs, the tags on all of them).
    let applied: [String]
    /// Tags on only some of several nogs: a dash, and a tap puts them on all.
    var partial: [String] = []
    /// Tags that can't be taken off here.
    var fixed: Set<String> = []
    let add: (String) -> Void
    let remove: (String) -> Void
    /// The button's look. The drawer is drawn from it, so the two always match.
    var look: NewtonLook = .tinted(Theme.blue)
    var style: DrawerButtonStyle = .newton
    var font: Font? = nil
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        DrawerButton(title: "Tags", look: look, style: style, font: font, content: { context in
            AnyView(TagMenuRows(applied: applied, partial: partial, fixed: fixed,
                                add: add, remove: remove, context: context))
        }, label: label)
    }
}

/// The drawer's rows: tags, then New… and More….
private struct TagMenuRows: View {
    let applied: [String]
    let partial: [String]
    let fixed: Set<String>
    let add: (String) -> Void
    let remove: (String) -> Void
    let context: DrawerContext
    @Environment(ItemStore.self) private var store
    @ScaledMetric(relativeTo: .subheadline) private var fieldWidth: CGFloat = 110
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 40
    @State private var showingAll = false
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var fieldFocused: Bool
    /// VoiceOver starts on the first row when the menu opens.
    @AccessibilityFocusState private var voFocus: String?

    static var shown: Int { 7 }

    /// Narrow comes first: longer tags are cut with "…".
    private var maxWidth: CGFloat { max(context.anchorWidth, 180) }

    var body: some View {
        let all = allTags
        let rows = showingAll ? all : Array(all.prefix(Self.shown))
        // The list scrolls when it can't fit (all tags, or very large text).
        let listHeight = min(CGFloat(rows.count) * rowHeight, max(context.maxHeight - 2 * rowHeight - 4, rowHeight * 2))
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.self) { tag in
                            tagRow(tag)
                                .accessibilityFocused($voFocus, equals: tag)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: listHeight)
                rule
            }
            if naming {
                nameField
            } else {
                Button { naming = true } label: {
                    row(mark: "plus", text: "New…")
                }
                .buttonStyle(NewtonRowStyle(tint: Theme.violet))
                .accessibilityLabel("New tag")
            }
            if all.count > Self.shown && !showingAll {
                Button { showingAll = true } label: {
                    row(mark: "ellipsis", text: "More…")
                }
                .buttonStyle(NewtonRowStyle(tint: Theme.muted))
                .accessibilityLabel("More tags, \(all.count - Self.shown) more")
            }
        }
        .padding(.vertical, 2)
        // As narrow as the tags allow, never narrower than the button itself.
        .frame(minWidth: context.anchorWidth, maxWidth: maxWidth, alignment: .leading)
        .onAppear { voFocus = allTags.first }
    }

    /// The nog's tags first, then every other tag, most used and most recent first.
    private var allTags: [String] {
        let mine = applied + partial
        let others = TagSuggester.suggest("", from: TagSuggester.stats(store.items.values),
                                          excluding: Set(mine), limit: .max)
        return mine + others
    }

    private func isOn(_ tag: String) -> Bool {
        applied.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func isPartial(_ tag: String) -> Bool {
        partial.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func tagRow(_ tag: String) -> some View {
        let on = isOn(tag)
        let onSome = !on && isPartial(tag)
        let isFixed = fixed.contains(tag)
        let color = TagPalette.tint(for: tag)
        return Button {
            on ? remove(tag) : add(tag)
            context.close()
        } label: {
            row(mark: on ? "checkmark" : onSome ? "minus" : nil, text: "#\(tag)")
        }
        .buttonStyle(NewtonRowStyle(tint: color))
        // Ticked at full strength, never a dimmed dead-looking row.
        .allowsHitTesting(!isFixed)
        .accessibilityLabel(isFixed ? "\(tag), typed in the text" : onSome ? "\(tag), on some" : tag)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(on ? "Takes the tag off" : onSome ? "Puts the tag on all of them" : "Puts the tag on")
    }

    /// One tight row: a narrow column for the tick, then the text.
    private func row(mark: String?, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: mark ?? "checkmark")
                .font(.caption.weight(.bold))
                .opacity(mark == nil ? 0 : 1)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .font(.subheadline)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(minHeight: rowHeight)
        // Every row as wide as the menu, so a pressed row inverts edge to edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var nameField: some View {
        HStack(spacing: 6) {
            Text("#")
                .foregroundStyle(Theme.violet)
                .frame(width: 12)
                .accessibilityHidden(true)
            TextField("new tag", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    let tag = Item.cleanTag(newName)
                    if !tag.isEmpty { add(tag) }
                    context.close()
                }
                .frame(width: fieldWidth)
                .onAppear { fieldFocused = true }
                .accessibilityLabel("New tag name")
                .accessibilityHint("Type a name, then press Done.")
        }
        .font(.subheadline)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(minHeight: rowHeight)
    }

    private var rule: some View {
        Rectangle().fill(Theme.edge).frame(height: 1).accessibilityHidden(true)
    }
}
