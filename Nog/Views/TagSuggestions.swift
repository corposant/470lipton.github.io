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
/// the spirit of the Newton's pickers: the button pulls out into a drawer in its own style
/// (a fade with Reduce Motion), as narrow as the tags allow but never narrower than the
/// button, one tight row per tag, a tick on the left for tags that are on. Tap a tag to
/// put it on (or take it off) and the menu closes. "New…"
/// turns into a field in place (the only time the keyboard comes up); "More…" shows every
/// tag once there are more than seven. The drawer touches its button and shares that edge
/// (near-square corners there, a shallow inner shadow), so the two read as one piece.
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
    /// The button's own look, so the menu reads as the button pulled out into a drawer.
    var drawer: TagDrawerStyle = .standard
    @ViewBuilder let label: () -> MenuLabel
    @State private var frame: CGRect = .zero
    @State private var openID: UUID?
    /// VoiceOver goes back to the button when its menu closes.
    @AccessibilityFocusState private var buttonFocused: Bool

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
        let request = TagMenuCenter.Request(anchor: frame, applied: applied, fixed: fixed,
                                            style: drawer, add: add, remove: remove)
        openID = request.id
        center.open(request)
    }
}

/// How a tag button is drawn, so its drawer can match: the same fill and outline, and the
/// same corners (nil = round ends, like a capsule button).
struct TagDrawerStyle {
    var fill: Color
    var stroke: Color = .clear
    var lineWidth: CGFloat = 1
    var cornerRadius: CGFloat? = nil

    /// The Map card's bordered button. The faint outline keeps the drawer's edge
    /// visible on the dark theme, where a shadow wouldn't show.
    static let standard = TagDrawerStyle(fill: Theme.blue.opacity(0.15), stroke: Theme.blue.opacity(0.4))
}

/// The small mark that says "this opens a list": a subtle diamond, as on the Newton.
struct PickerMark: View {
    var body: some View {
        Image(systemName: "diamond.fill")
            .font(.system(.caption2, weight: .bold))
            .imageScale(.small)
            .scaleEffect(0.6)
            .opacity(0.6)
            .accessibilityHidden(true)
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
        let style: TagDrawerStyle
        let add: (String) -> Void
        let remove: (String) -> Void
    }

    var request: Request? {
        didSet { if let request { lastAnchor = request.anchor } }
    }
    /// Where the last menu opened, kept after it closes so it slides back into its button.
    private(set) var lastAnchor: CGRect = .zero

    func open(_ request: Request) {
        withNogAnimation(.snappy(duration: 0.24, extraBounce: 0.08)) { self.request = request }
    }

    func close() {
        withNogAnimation(.snappy(duration: 0.18)) { request = nil }
    }
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
            let anchor = center.lastAnchor.offsetBy(dx: -origin.x, dy: -origin.y)
            // Open upwards from buttons in the lower half (the Map card, the capture tray).
            let up = anchor.midY > geo.size.height / 2
            let room = up ? anchor.minY - 12 : geo.size.height - anchor.maxY - 12
            ZStack(alignment: .topLeading) {
                if center.request != nil {
                    // Tap anywhere else to close.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { center.close() }
                        .accessibilityHidden(true)
                }
                TagMenuPlacement(anchor: anchor, up: up) {
                    if let request = center.request {
                        TagMenuPanel(request: request, up: up, maxHeight: max(room, 120)) { center.close() }
                            .id(request.id)
                            .fixedSize()
                            // Pulls out of the button like a drawer: revealed from the button's edge.
                            .transition(.nog(.modifier(active: DrawerReveal(open: 0, fromBottom: up),
                                                       identity: DrawerReveal(open: 1, fromBottom: up))
                                .combined(with: .opacity)))
                    }
                }
            }
        }
    }
}

/// Puts the menu right against (or below) its button, kept on screen. A layout, not a
/// measure-then-move, so it's in the right place from the first frame.
private struct TagMenuPlacement: Layout {
    let anchor: CGRect
    let up: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let x = min(max(anchor.minX, 8), bounds.width - size.width - 8)
            // Touching the button: one piece with it.
            let y = up ? anchor.minY - size.height : anchor.maxY
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
        }
    }
}

/// Reveals the drawer from the button's edge outwards.
private struct DrawerReveal: ViewModifier {
    let open: CGFloat
    let fromBottom: Bool

    func body(content: Content) -> some View {
        content.mask {
            Rectangle()
                .scaleEffect(x: 1, y: max(open, 0.001), anchor: fromBottom ? .bottom : .top)
        }
    }
}

/// The panel: tag rows, then New… and More….
private struct TagMenuPanel: View {
    let request: TagMenuCenter.Request
    /// Opens upwards, so the button is at its bottom edge.
    let up: Bool
    let maxHeight: CGFloat
    let close: () -> Void
    @Environment(ItemStore.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var fieldWidth: CGFloat = 110
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 40
    @State private var showingAll = false
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var fieldFocused: Bool
    /// VoiceOver starts on the first row when the menu opens.
    @AccessibilityFocusState private var voFocus: String?

    static var shown: Int { 7 }

    /// The button's corners (its own radius, or round ends for a capsule) on the far side;
    /// nearly square where the drawer meets the button, so they share that edge.
    private var shape: UnevenRoundedRectangle {
        let far = request.style.cornerRadius ?? min(request.anchor.height / 2, 18)
        let near: CGFloat = 3
        return UnevenRoundedRectangle(topLeadingRadius: up ? far : near, bottomLeadingRadius: up ? near : far,
                                      bottomTrailingRadius: up ? near : far, topTrailingRadius: up ? far : near,
                                      style: .continuous)
    }

    /// Wider at the accessibility text sizes, where 180pt would cut most tags short.
    private var maxWidth: CGFloat {
        max(request.anchor.width, typeSize.isAccessibilitySize ? 320 : 180)
    }

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
        // As narrow as the tags allow, never narrower than the button itself.
        .frame(minWidth: request.anchor.width, maxWidth: maxWidth, alignment: .leading)
        .background {
            ZStack {
                Theme.base
                request.style.fill
            }
        }
        // A little depth: a shallow inner shadow at the button's edge, as if the rows
        // sit in a well the button pulled open.
        .overlay(alignment: up ? .bottom : .top) {
            LinearGradient(colors: [.black.opacity(0.2), .clear],
                           startPoint: up ? .bottom : .top, endPoint: up ? .top : .bottom)
                .frame(height: 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(contrast == .increased && request.style.stroke == .clear
                                        ? Theme.edgeStrong : request.style.stroke,
                                    lineWidth: request.style.lineWidth))
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
