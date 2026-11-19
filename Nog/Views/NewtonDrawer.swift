import SwiftUI

// Nog's menus, drawn in the spirit of the Newton's pickers. The button and its drawer are
// one piece: when it opens, the button's own outline stretches out to wrap the menu, and
// the rows slide out from under the button like a drawer on runners (a fade with Reduce
// Motion). As narrow as the rows allow but never narrower than the button, 40pt rows, a
// tick on the left for what's on. Tap a row and the drawer closes.
//
// The open drawer, button and all, is drawn by `DrawerHost` at the top of the window, so
// nothing the button sits inside (a scrolling chip row, a card, the top bar) can clip it.
// The real button hides underneath while it's open.

/// What a drawer's rows get to work with.
struct DrawerContext {
    /// The button's width: rows are never narrower.
    let anchorWidth: CGFloat
    /// The most height the rows can take before they have to scroll.
    let maxHeight: CGFloat
    /// The drawer's colour, for rows that don't have their own.
    let tint: Color
    /// Closes the drawer (it slides back into the button).
    let close: () -> Void
}

/// How the button looks while its drawer is closed.
enum DrawerButtonStyle {
    /// A Newton-style button in the drawer's own look, so closed and open are one piece.
    case newton
    /// Leave the button as its surroundings draw it (a top-bar button in its glass, a
    /// glass circle). The drawer draws it in the drawer's look while open.
    case bare
}

/// A button that opens a drawer menu. `content` builds the rows; most menus use
/// `DrawerMenuRows`, the tag menu uses its own.
struct DrawerButton<Label: View>: View {
    /// What VoiceOver calls the open drawer ("Tags", "Sort and show").
    let title: String
    /// The drawer's look (and the button's, with `.newton`).
    var look: NewtonLook = .tinted(Theme.blue)
    var style: DrawerButtonStyle = .newton
    /// The font the label is drawn in. Nil: whatever font the button sits in.
    var font: Font? = nil
    let content: (DrawerContext) -> AnyView
    @ViewBuilder let label: () -> Label
    @Environment(\.font) private var environmentFont
    /// Which host draws the drawer: the window's, or a sheet's own.
    @Environment(\.drawerScope) private var scope
    @State private var frame: CGRect = .zero
    @State private var openID: UUID?
    /// VoiceOver goes back to the button when its drawer closes.
    @AccessibilityFocusState private var buttonFocused: Bool

    private var center: DrawerCenter { .shared }
    private var isOpen: Bool { openID != nil && center.request?.id == openID }

    var body: some View {
        styled(Button(action: toggleOpen) { fontedLabel })
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

    @ViewBuilder
    private var fontedLabel: some View {
        if let font { label().font(font) } else { label() }
    }

    @ViewBuilder
    private func styled<B: View>(_ button: B) -> some View {
        switch style {
        case .newton: button.buttonStyle(.newton(look))
        case .bare: button
        }
    }

    private func toggleOpen() {
        if isOpen { center.close(); return }
        let request = DrawerCenter.Request(anchor: frame, scope: scope, title: title, look: look,
                                           font: font ?? environmentFont ?? .subheadline,
                                           label: AnyView(label()), content: content)
        openID = request.id
        center.open(request)
    }
}

/// The one drawer that's open, if any.
@MainActor @Observable
final class DrawerCenter {
    static let shared = DrawerCenter()

    struct Request {
        let id = UUID()
        /// The button's frame, in window coordinates.
        var anchor: CGRect
        /// The host that draws it (see `drawerHost(scope:)`).
        let scope: String
        let title: String
        let look: NewtonLook
        /// The button's font and label, so the drawer can draw the button as its own edge.
        let font: Font
        let label: AnyView
        let content: (DrawerContext) -> AnyView
    }

    /// The drawer on screen, open or closing.
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

extension EnvironmentValues {
    /// The drawer host that buttons inside this view open their drawers in.
    @Entry var drawerScope = "root"
}

extension View {
    /// Draws the open drawer menu over everything. Put it once on the root view, and once
    /// on each sheet that has drawer buttons (a sheet sits above the root's host), with a
    /// scope of its own.
    func drawerHost(scope: String = "root") -> some View {
        environment(\.drawerScope, scope)
            .overlay { DrawerHost(scope: scope) }
    }
}

private struct DrawerHost: View {
    let scope: String
    private var center: DrawerCenter { .shared }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if let request = center.request, request.scope == scope {
                    let anchor = request.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                    // Open upwards from buttons in the lower half (the Map card, the capture tray).
                    let up = anchor.midY > geo.size.height / 2
                    // Tap anywhere else to close.
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { center.close() }
                        .accessibilityHidden(true)
                    NewtonDrawer(request: request, anchor: anchor, up: up, isOut: center.isOut,
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
private struct NewtonDrawer: View {
    let request: DrawerCenter.Request
    /// The button's frame, in this view's coordinates.
    let anchor: CGRect
    /// Opens upwards, so the button is at the bottom.
    let up: Bool
    let isOut: Bool
    let screen: CGSize
    let close: () -> Void
    private var center: DrawerCenter { .shared }
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
        .accessibilityLabel(request.title)
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
        let context = DrawerContext(anchorWidth: anchor.width, maxHeight: max(room, 120),
                                    tint: request.look.foreground, close: close)
        return request.content(context)
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

// MARK: Ordinary menus

/// One row in a drawer menu.
struct DrawerItem: Identifiable {
    let id: String
    let title: String
    /// A second, smaller line (what a layout does, say).
    var detail: String? = nil
    var systemImage: String? = nil
    /// Nil for an action. True or false for a choice or a switch: a tick when on.
    var isOn: Bool? = nil
    /// The row's colour. Nil: the drawer's colour (pink for a destructive row).
    var tint: Color? = nil
    var isDestructive = false
    var isEnabled = true
    var hint: String? = nil
    let action: () -> Void

    init(_ title: String, id: String? = nil, detail: String? = nil, systemImage: String? = nil,
         isOn: Bool? = nil, tint: Color? = nil, isDestructive: Bool = false, isEnabled: Bool = true,
         hint: String? = nil, action: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isOn = isOn
        self.tint = tint
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.hint = hint
        self.action = action
    }
}

/// A group of rows, with a rule above it (and a small title, if it has one).
struct DrawerSection: Identifiable {
    let id: String
    var title: String?
    var items: [DrawerItem]

    init(_ title: String? = nil, id: String? = nil, items: [DrawerItem]) {
        self.id = id ?? title ?? items.map(\.id).joined(separator: "|")
        self.title = title
        self.items = items
    }
}

extension DrawerButton {
    /// A drawer of ordinary rows.
    init(_ title: String, look: NewtonLook = .tinted(Theme.blue), style: DrawerButtonStyle = .newton,
         font: Font? = nil, maxWidth: CGFloat = 230,
         sections: @escaping () -> [DrawerSection], @ViewBuilder label: @escaping () -> Label) {
        self.init(title: title, look: look, style: style, font: font, content: { context in
            AnyView(DrawerMenuRows(sections: sections(), context: context, maxWidth: maxWidth))
        }, label: label)
    }
}

/// A drawer's rows: tight, 40pt, a tick column only when something can be ticked, an
/// icon column only when rows have icons. Sections are split by a rule.
struct DrawerMenuRows: View {
    let sections: [DrawerSection]
    let context: DrawerContext
    var maxWidth: CGFloat = 230
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 20
    @State private var contentHeight: CGFloat = 0
    /// VoiceOver starts on the first row when the drawer opens.
    @AccessibilityFocusState private var voFocus: String?

    private var items: [DrawerItem] { sections.flatMap(\.items) }
    private var hasTicks: Bool { items.contains { $0.isOn != nil } }
    private var hasIcons: Bool { items.contains { $0.systemImage != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { rule }
                    if let title = section.title {
                        Text(title.uppercased())
                            .font(.nogMicroLabel)
                            .tracking(1.4)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(section.items) { item in
                        row(item)
                            .accessibilityFocused($voFocus, equals: item.id)
                    }
                }
            }
            .padding(.vertical, 2)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Its full height, until that's more than there's room for: then it scrolls.
        .frame(height: min(contentHeight, context.maxHeight))
        // As narrow as the rows allow, never narrower than the button itself.
        .frame(minWidth: context.anchorWidth, maxWidth: max(context.anchorWidth, maxWidth), alignment: .leading)
        .onAppear { voFocus = items.first(where: \.isEnabled)?.id }
    }

    private func row(_ item: DrawerItem) -> some View {
        let tint = item.tint ?? (item.isDestructive ? Theme.pink : context.tint)
        return Button {
            context.close()
            item.action()
        } label: {
            HStack(spacing: 6) {
                if hasTicks {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .opacity(item.isOn == true ? 1 : 0)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                }
                if hasIcons {
                    Image(systemName: item.systemImage ?? "circle")
                        .opacity(item.systemImage == nil ? 0 : 1)
                        .frame(width: iconWidth)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption)
                            .opacity(0.75)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
            }
            .font(.subheadline)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, item.detail == nil ? 0 : 5)
            .frame(minHeight: rowHeight)
            // Every row as wide as the menu, so a pressed row inverts edge to edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NewtonRowStyle(tint: tint))
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(item.isOn == true ? .isSelected : [])
        .accessibilityHint(item.hint ?? "")
    }

    private var rule: some View {
        Rectangle().fill(Theme.edge).frame(height: 1).accessibilityHidden(true)
    }
}

/// A Newton-style row: pressed, it inverts (filled with its colour, text in the background colour).
struct NewtonRowStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.base : tint)
            .background(configuration.isPressed ? tint : .clear)
    }
}

// MARK: Pickers

/// A settings row: the name on the left, the current choice as a Newton button on the
/// right. Tap it and the choices slide out of it as a drawer, the current one ticked.
/// Used in place of the stock menu picker in Settings and the Nog sheet.
struct DrawerPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var tint: Color = Theme.blue

    init(_ title: String, selection: Binding<Value>, options: [Value], tint: Color = Theme.blue,
         label: @escaping (Value) -> String) {
        self.title = title
        self._selection = selection
        self.options = options
        self.tint = tint
        self.label = label
    }

    var body: some View {
        LabeledContent {
            DrawerButton(title, look: .tinted(tint), font: .subheadline, maxWidth: 240, sections: {
                [DrawerSection(id: "choices", items: options.enumerated().map { index, option in
                    DrawerItem(label(option), id: "\(index)", isOn: option == selection) {
                        selection = option
                    }
                })]
            }) {
                Text(label(selection))
            }
            .accessibilityLabel(title)
            .accessibilityValue(label(selection))
            .accessibilityHint("Opens the choices")
        } label: {
            Text(title)
        }
    }
}
