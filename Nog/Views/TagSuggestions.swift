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
/// the spirit of the Newton's pickers. The button and its drawer are one piece: when it
/// opens, the button's own outline stretches out to wrap the menu, and the rows slide out
/// from under the button like a drawer on runners (a fade with Reduce Motion). As narrow
/// as the tags allow but never narrower than the button, one tight row per tag, a tick on
/// the left for tags that are on. Tap a tag to put it on (or take it off) and the menu
/// closes. "New…" turns into a field in place (the only time the keyboard comes up);
/// "More…" shows every tag once there are more than seven.
///
/// The open drawer, button and all, is drawn by `TagMenuHost` at the top of the window,
/// so nothing it sits inside (a scrolling chip row, a card) can clip it. The real button
/// hides underneath while it's open.
struct TagMenu<MenuLabel: View>: View {
    /// The tags on the nog now.
    let applied: [String]
    /// Tags that can't be taken off here (in New Nog, the ones typed in the text).
    var fixed: Set<String> = []
    let add: (String) -> Void
    let remove: (String) -> Void
    /// The button's look. The drawer is drawn from it, so the two always match.
    var look: NewtonLook = .tinted(Theme.blue)
    @ViewBuilder let label: () -> MenuLabel
    @Environment(\.font) private var font
    @State private var frame: CGRect = .zero
    @State private var openID: UUID?
    /// VoiceOver goes back to the button when its menu closes.
    @AccessibilityFocusState private var buttonFocused: Bool

    private var center: TagMenuCenter { .shared }
    private var isOpen: Bool { openID != nil && center.request?.id == openID }

    var body: some View {
        Button(action: toggleOpen) { label() }
            .buttonStyle(.newton(look))
            // While open, the drawer draws this button as its top (or bottom) edge.
            .opacity(isOpen ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in
                frame = new
                // Follow the button (the Map card rises with the keyboard, say).
                if isOpen { center.move(to: new) }
            }
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            .accessibilityFocused($buttonFocused)
            .onChange(of: isOpen) { _, open in
                if !open, openID != nil {
                    openID = nil
                    buttonFocused = true
                }
            }
            .onDisappear { if isOpen { center.close() } }
    }

    private func toggleOpen() {
        if isOpen { center.close(); return }
        let request = TagMenuCenter.Request(anchor: frame, applied: applied, fixed: fixed, look: look,
                                            font: font ?? .subheadline, label: AnyView(label()),
                                            add: add, remove: remove)
        openID = request.id
        center.open(request)
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
        let look: NewtonLook
        /// The button's font and label, so the drawer can draw the button as its own edge.
        let font: Font
        let label: AnyView
        let add: (String) -> Void
        let remove: (String) -> Void
    }

    /// The menu on screen, open or closing.
    private(set) var request: Request?
    /// Pulled out (true) or tucked back into the button (false). Animated on its own, so
    /// the drawer appears closed, looking exactly like its button, then slides open.
    private(set) var isOut = false

    /// A drawer on runners: quick to start, a soft stop at the end.
    private static let pullOut = Animation.spring(response: 0.34, dampingFraction: 0.84)
    private static let pushIn = Animation.snappy(duration: 0.2)

    func open(_ request: Request) {
        if Calm.reducesMotion {
            // No sliding: the open drawer fades in where it is.
            isOut = true
            withAnimation(.easeOut(duration: 0.12)) { self.request = request }
            return
        }
        // Closed for now: the drawer lies exactly over its button. It slides out once its
        // rows are measured (`slideOut`).
        isOut = false
        self.request = request
    }

    /// Called by the drawer once it knows how big its rows are. Waits a frame, so the
    /// closed drawer is on screen before it starts to move.
    func slideOut(_ id: UUID) {
        guard !isOut else { return }
        DispatchQueue.main.async { [self] in
            guard request?.id == id, !isOut else { return }
            withAnimation(Self.pullOut) { isOut = true }
        }
    }

    func close() {
        guard let id = request?.id else { return }
        if Calm.reducesMotion {
            withAnimation(.easeIn(duration: 0.1)) { request = nil }
            return
        }
        withAnimation(Self.pushIn) {
            isOut = false
        } completion: { [self] in
            if request?.id == id { request = nil }
        }
    }

    /// Updates where the button is, so an open drawer follows it.
    func move(to anchor: CGRect) { request?.anchor = anchor }
}

extension View {
    /// Draws the open tag menu over everything. Put it once, on the root view.
    func tagMenuHost() -> some View {
        overlay { TagMenuHost() }
    }
}

private struct TagMenuHost: View {
    private var center: TagMenuCenter { .shared }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if let request = center.request {
                    let anchor = request.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                    // Open upwards from buttons in the lower half (the Map card, the capture tray).
                    let up = anchor.midY > geo.size.height / 2
                    // Tap anywhere else to close.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { center.close() }
                        .accessibilityHidden(true)
                    TagDrawer(request: request, anchor: anchor, up: up, isOut: center.isOut,
                              screen: geo.size, close: { center.close() })
                        .id(request.id)
                        .transition(Calm.reducesMotion ? .opacity : .identity)
                }
            }
        }
    }
}

/// The button and its drawer as one piece: one outline, one fill. Closed, it is exactly
/// the button. Opening, the outline grows out of the button's far edge and the rows
/// slide out from under the button, far end first, like a drawer being pulled.
private struct TagDrawer: View {
    let request: TagMenuCenter.Request
    /// The button's frame, in this view's coordinates.
    let anchor: CGRect
    /// Opens upwards, so the button is at the bottom.
    let up: Bool
    let isOut: Bool
    let screen: CGSize
    let close: () -> Void
    private var center: TagMenuCenter { .shared }
    @Environment(\.colorSchemeContrast) private var contrast
    /// The rows at their natural size. The drawer slides out once they're known.
    @State private var rows: CGSize = .zero

    private let margin: CGFloat = 8

    var body: some View {
        let look = request.look
        let width = isOut ? max(anchor.width, rows.width) : anchor.width
        let height = isOut ? rows.height : 0
        // A wide drawer near the right edge grows leftwards too, so it stays on screen.
        let shift = max(0, min(anchor.minX + width - (screen.width - margin), anchor.minX - margin))
        let room = up ? anchor.minY - 12 : screen.height - anchor.maxY - 12
        VStack(alignment: .leading, spacing: 0) {
            if up { well(height: height, room: room) }
            cap
                .padding(.leading, shift)
            if !up { well(height: height, room: room) }
        }
        .frame(width: width, alignment: .leading)
        .background {
            // Paper under the button's own wash, so nothing shows through the drawer.
            ZStack { Theme.base; look.fill }
        }
        .clipShape(look.shape)
        .overlay(look.shape.strokeBorder(contrast == .increased ? look.foreground : look.stroke,
                                         lineWidth: contrast == .increased ? max(look.lineWidth, 2) : look.lineWidth))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        // Pinned to the button: its top edge for a drawer that opens down, its bottom edge
        // for one that opens up. The drawer grows away from the button.
        .frame(width: screen.width, height: up ? anchor.maxY : max(screen.height - anchor.minY, 0),
               alignment: up ? .bottomLeading : .topLeading)
        .offset(x: anchor.minX - shift, y: up ? 0 : anchor.minY)
    }

    /// The button itself, drawn as the drawer's edge. Tap it to close.
    private var cap: some View {
        request.label
            .font(request.font)
            .lineLimit(1)
            .foregroundStyle(request.look.foreground)
            .frame(width: anchor.width, height: anchor.height)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .accessibilityHidden(true)
    }

    /// The rows, in a frame that grows as the drawer opens. They're pinned to the far edge,
    /// so they slide out from under the button rather than unrolling in place.
    private func well(height: CGFloat, room: CGFloat) -> some View {
        TagMenuRows(request: request, maxHeight: max(room, 120), close: close)
            .fixedSize()
            // Their natural size, whatever the frame below lets show.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                rows = size
                if size.height > 0 { center.slideOut(request.id) }
            }
            .frame(height: height, alignment: up ? .top : .bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            // Where the drawer meets the button: a hairline, and a shallow shadow as if the
            // rows sit a little below the button's face.
            .overlay(alignment: up ? .bottom : .top) {
                VStack(spacing: 0) {
                    if !up { hairline }
                    LinearGradient(colors: [.black.opacity(0.18), .clear],
                                   startPoint: up ? .bottom : .top, endPoint: up ? .top : .bottom)
                        .frame(height: 7)
                    if up { hairline }
                }
                // Only once the drawer is out: closed, it must look exactly like the button.
                .opacity(isOut ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private var hairline: some View {
        Rectangle().fill(request.look.stroke.opacity(0.5)).frame(height: 1)
    }
}

/// The drawer's rows: tags, then New… and More….
private struct TagMenuRows: View {
    let request: TagMenuCenter.Request
    let maxHeight: CGFloat
    let close: () -> Void
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
    private var maxWidth: CGFloat { max(request.anchor.width, 180) }

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
        .frame(minWidth: request.anchor.width, maxWidth: maxWidth, alignment: .leading)
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
        // Ticked at full strength, never a dimmed dead-looking row.
        .allowsHitTesting(!isFixed)
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
                    if !tag.isEmpty { request.add(tag) }
                    close()
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

/// A Newton-style row: pressed, it inverts (filled with its colour, text in the background colour).
private struct NewtonRowStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.base : tint)
            .background(configuration.isPressed ? tint : .clear)
    }
}
