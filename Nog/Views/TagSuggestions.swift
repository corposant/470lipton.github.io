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

/// The tag menu, shared by New Nog's Tags chip and the Map's info card. Drawn by us, in
/// the spirit of the Newton's pickers: it pops up right at the button with no animation,
/// a plain panel with a thin border and a hard shadow, one tight row per tag, a tick on
/// the left for tags that are on. Tap a tag to put it on (or take it off) and the menu
/// closes. "New tag…" turns into a field in place (the only time the keyboard comes up);
/// "More…" shows every tag once there are more than seven.
///
/// The panel itself is drawn by `TagMenuHost` at the top of the window, so nothing it
/// sits inside (a scrolling chip row, a card) can clip it.
struct TagMenu<MenuLabel: View>: View {
    /// The tags on the nog now.
    let applied: [String]
    /// Tags that can't be taken off here (in New Nog, the ones typed in the text).
    var fixed: Set<String> = []
    let add: (String) -> Void
    let remove: (String) -> Void
    @ViewBuilder let label: () -> MenuLabel
    @State private var frame: CGRect = .zero
    @State private var openID: UUID?

    private var center: TagMenuCenter { .shared }
    private var isOpen: Bool { openID != nil && center.request?.id == openID }

    var body: some View {
        Button(action: toggleOpen) { label() }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in
                frame = new
                // Follow the button (the Map card rises with the keyboard, say).
                if isOpen { center.request?.anchor = new }
            }
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            .onDisappear { if isOpen { center.close() } }
    }

    private func toggleOpen() {
        if isOpen { center.close(); return }
        let request = TagMenuCenter.Request(anchor: frame, applied: applied, fixed: fixed,
                                            add: add, remove: remove)
        openID = request.id
        center.request = request
    }
}

/// The one tag menu that's open, if any.
@MainActor @Observable
final class TagMenuCenter {
    static let shared = TagMenuCenter()

    struct Request {
        let id = UUID()
        /// The button's frame, in window coordinates.
        var anchor: CGRect
        let applied: [String]
        let fixed: Set<String>
        let add: (String) -> Void
        let remove: (String) -> Void
    }

    var request: Request?

    func close() { request = nil }
}

extension View {
    /// Draws the open tag menu over everything. Put it once, on the root view.
    func tagMenuHost() -> some View {
        overlay { TagMenuHost() }
    }
}

private struct TagMenuHost: View {
    private var center: TagMenuCenter { .shared }
    @State private var size: CGSize = .zero

    var body: some View {
        if let request = center.request {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                let anchor = request.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                let bounds = geo.size
                // Open upwards from buttons in the lower half (the Map card, the capture tray).
                let up = anchor.midY > bounds.height / 2
                let room = up ? anchor.minY - geo.safeAreaInsets.top - 12
                              : bounds.height - anchor.maxY - geo.safeAreaInsets.bottom - 12
                ZStack(alignment: .topLeading) {
                    // Tap anywhere else to close, as on the Newton.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { center.close() }
                        .accessibilityHidden(true)
                    TagMenuPanel(request: request, maxHeight: max(room, 120)) { center.close() }
                        .id(request.id)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                        .offset(x: min(max(anchor.minX, 8), bounds.width - size.width - 8),
                                y: up ? anchor.minY - size.height - 4 : anchor.maxY + 4)
                        // Hidden for the one pass before it's measured, so it never jumps.
                        .opacity(size == .zero ? 0 : 1)
                }
            }
            .onDisappear { size = .zero }
        }
    }
}

/// The panel: tag rows, then New tag… and More….
private struct TagMenuPanel: View {
    let request: TagMenuCenter.Request
    let maxHeight: CGFloat
    let close: () -> Void
    @Environment(ItemStore.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 32
    @State private var showingAll = false
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var fieldFocused: Bool
    /// VoiceOver starts on the first row when the menu opens.
    @AccessibilityFocusState private var voFocus: String?

    static var shown: Int { 7 }

    var body: some View {
        let all = allTags
        let rows = showingAll ? all : Array(all.prefix(Self.shown))
        // The list scrolls when it can't fit (all tags, or very large text).
        let listHeight = min(CGFloat(rows.count) * rowHeight, max(maxHeight - 2 * rowHeight - 4, rowHeight * 2))
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
                    row(mark: "plus", text: "New tag…")
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
        .frame(minWidth: 132, maxWidth: 260, alignment: .leading)
        .background(Theme.base)
        .overlay(Rectangle().strokeBorder(contrast == .increased ? Theme.edgeStrong : Theme.edge, lineWidth: 1))
        // A hard shadow, no blur: quick to draw and crisp.
        .background(Rectangle().fill(Theme.violet.opacity(0.35)).offset(x: 3, y: 3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .onAppear { voFocus = allTags.first }
    }

    /// The nog's tags first, then every other tag, most used and most recent first.
    private var allTags: [String] {
        let others = TagSuggester.suggest("", from: TagSuggester.stats(store.items.values),
                                          excluding: Set(request.applied), limit: .max)
        return request.applied + others
    }

    private func isOn(_ tag: String) -> Bool {
        request.applied.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func tagRow(_ tag: String) -> some View {
        let on = isOn(tag)
        let isFixed = request.fixed.contains(tag)
        let color = TagPalette.tint(for: tag)
        return Button {
            on ? request.remove(tag) : request.add(tag)
            close()
        } label: {
            row(mark: on ? "checkmark" : nil, text: "#\(tag)")
        }
        .buttonStyle(NewtonRowStyle(tint: color))
        .disabled(isFixed)
        .opacity(isFixed ? 0.6 : 1)
        .accessibilityLabel(isFixed ? "\(tag), typed in the text" : tag)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(on ? "Takes the tag off" : "Puts the tag on")
    }

    /// One tight row: a narrow column for the tick, then the text.
    private func row(mark: String?, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: mark ?? "checkmark")
                .font(.caption.weight(.bold))
                .opacity(mark == nil ? 0 : 1)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 10)
        }
        .font(.subheadline)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(minHeight: rowHeight)
        // Every row as wide as the menu, so a pressed row inverts edge to edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var nameField: some View {
        HStack(spacing: 6) {
            Text("#")
                .foregroundStyle(Theme.violet)
                .frame(width: 14)
                .accessibilityHidden(true)
            TextField("new tag", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    let tag = Item.cleanTag(newName)
                    if !tag.isEmpty { request.add(tag) }
                    close()
                }
                .frame(width: 150)
                .onAppear { fieldFocused = true }
                .accessibilityLabel("New tag name")
                .accessibilityHint("Type a name, then press Done.")
        }
        .font(.subheadline)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(minHeight: rowHeight)
    }

    private var rule: some View {
        Rectangle().fill(Theme.edge).frame(height: 1).accessibilityHidden(true)
    }
}

/// A Newton-style row: pressed, it inverts (filled with its colour, text in the background colour).
private struct NewtonRowStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.base : tint)
            .background(configuration.isPressed ? tint : .clear)
    }
}
