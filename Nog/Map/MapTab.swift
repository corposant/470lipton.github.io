import PencilKit
import SwiftUI

/// See your data: a draggable mind map (with tag zones and scribbling) or an
/// Obsidian-style outline of projects and their sub-items.
struct MapTab: View {
    enum Mode: String, CaseIterable { case map = "Map", outline = "Outline" }

    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @State private var mode: Mode = .map
    @State private var pages = MapPages()
    @State private var showNogged = false
    /// The page you're on: "" = All, otherwise a tag. Remembered between launches.
    @AppStorage("mapPage") private var page = ""

    var body: some View {
        @Bindable var router = router
        let tags = MapPage.tags(Array(store.items.values), showNogged: showNogged)
        // If the tag you were on no longer has any items, fall back to All.
        let current = tags.contains { $0.tag == page } ? page : ""
        NavigationStack(path: $router.mapPath) {
            VStack(spacing: 0) {
                // The page strip is part of the page (not an inset), so the nav bar can't cover it.
                MapPageStrip(tags: tags, selected: current) { page = $0 }
                Group {
                    switch mode {
                    case .map:
                        MindMapView(doc: pages.doc(for: current),
                                    seed: current.isEmpty ? nil : pages.doc(for: ""),
                                    page: current, showNogged: showNogged)
                            .id(current) // fresh pan/zoom and centring per page
                    case .outline:
                        OutlineView(showNogged: showNogged, page: current)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background { NogBackground() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showNogged.toggle()
                    } label: {
                        Image(systemName: showNogged ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .accessibilityLabel(showNogged ? "Hide nogged items" : "Show nogged items")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
        }
    }
}

// MARK: - Mind map

struct MindMapView: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @Bindable var doc: MapDocument
    /// The All page, used to seed a tag page's first layout.
    var seed: MapDocument? = nil
    var page: String = ""
    let showNogged: Bool

    // The view transform: a map point p appears on screen at offset + p * scale.
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var didCenter = false
    @State private var isScribbling = false
    @State private var dragging: [UUID: CGPoint] = [:]
    /// The node a dragged node would be filed into if dropped now.
    @State private var dropTarget: UUID?
    @State private var scribble = ScribbleController()
    /// Locked: nodes can't be moved or filed, no scribbling or tidying (pan/zoom/tap still work).
    @AppStorage("mapLocked") private var locked = false
    /// Lets the Liquid Glass buttons morph into each other as the set changes.
    @Namespace private var glassSpace
    /// On a half-folded iPhone Duo, the larger side of the fold (Fit centres there).
    @State private var fitArea: CGRect?

    var body: some View {
        let items = MapPage.items(Array(store.items.values), page: page, showNogged: showNogged)
            .sorted { $0.created < $1.created }
        let edges = MapLayout.edges(for: items)
        let hasChildren = Set(items.compactMap(\.parentID))

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Scribbles sit underneath everything else. While scribbling, the nodes
                // ignore touches, so strokes reach this layer even where they pass under a node.
                // Scribbles are stored in map coordinates and shown through the current pan/zoom.
                ScribbleCanvas(drawing: doc.drawing.transformed(using: viewTransform),
                               isActive: isScribbling, controller: scribble) { onScreen in
                    doc.setDrawing(onScreen.transformed(using: viewTransform.inverted()))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(isScribbling)
                zones(items)
                edgeLayer(edges, size: geo.size)
                ForEach(items) { item in
                    MapNode(item: item, isFolder: hasChildren.contains(item.id), isDropTarget: dropTarget == item.id)
                        .scaleEffect(min(1.15, max(0.55, scale)))
                        .position(screen(mapPoint(item.id)))
                        .gesture(nodeDrag(item.id, among: items), including: locked ? .none : .all)
                        .onTapGesture { router.push(item.id) }
                        .contextMenu { nodeMenu(item) }
                        .allowsHitTesting(!isScribbling)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(panAndZoom(viewSize: geo.size), including: isScribbling ? .subviews : .all)
            .onAppear {
                // Load saved positions first, then lay out anything new, then centre.
                doc.load(from: store)
                if let seed {
                    seed.load(from: store)
                    doc.seedIfEmpty(from: seed, ids: items.map(\.id))
                }
                doc.placeMissing(items, edges: edges)
                centreIfNeeded(items, in: geo.size)
            }
            .onChange(of: geo.size) { centreIfNeeded(items, in: geo.size) }
            // Re-centre every time the map opens, once layout has settled.
            .onDisappear { didCenter = false }
            .task {
                await Task.yield()
                centreIfNeeded(items, in: geo.size)
            }
            .onChange(of: items.map(\.id)) { doc.placeMissing(items, edges: edges) }
            .onGeometryChange(for: CGRect?.self) { proxy in Self.largerPane(proxy) } action: { fitArea = $0 }
            .overlay(alignment: .bottomTrailing) {
                controls(items, edges: edges, size: geo.size)
                    .padding(.bottom, Self.controlsLift(geo))
                    .animation(.smooth, value: Self.controlsLift(geo))
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Nothing to map yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Capture a few things, give them #tags, sub-items or [[links]], and they'll show up here."))
                }
            }
        }
    }

    // MARK: Coordinates

    private var viewTransform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.width, ty: offset.height)
    }

    private func mapPoint(_ id: UUID) -> CGPoint {
        dragging[id] ?? doc.positions[id] ?? .zero
    }

    private func screen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: offset.width + p.x * scale, y: offset.height + p.y * scale)
    }

    private func screen(_ r: CGRect) -> CGRect {
        CGRect(x: offset.width + r.minX * scale, y: offset.height + r.minY * scale,
               width: r.width * scale, height: r.height * scale)
    }

    // MARK: Layers

    private struct Zone: Identifiable {
        let tag: String
        let rect: CGRect // map coordinates
        var id: String { tag }
    }

    /// One soft, coloured zone per #tag, wrapped around its items.
    @ViewBuilder
    private func zones(_ items: [Item]) -> some View {
        let zones: [Zone] = {
            var byTag: [String: [CGPoint]] = [:]
            for item in items {
                // Tags flow down, so a zone wraps a whole project with its sub-items.
                // On a tag's own page, its zone would just surround everything, so skip it.
                for tag in MapPage.effectiveTags(item, in: store.items) where tag != page {
                    byTag[tag, default: []].append(mapPoint(item.id))
                }
            }
            return byTag.compactMap { tag, points in
                guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                      let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
                let rect = CGRect(x: minX - 110, y: minY - 56, width: maxX - minX + 220, height: maxY - minY + 112)
                return Zone(tag: tag, rect: rect)
            }
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        }()
        ForEach(zones) { zone in
            let pair = TagPalette.color(for: zone.tag)
            let color = Color(light: pair.light, dark: pair.dark)
            let r = screen(zone.rect)
            RoundedRectangle(cornerRadius: 32 * scale, style: .continuous)
                .fill(color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 32 * scale, style: .continuous)
                    .strokeBorder(color.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
                .overlay(alignment: .topLeading) {
                    Text("#\(zone.tag.uppercased())")
                        .font(.nogLabel)
                        .tracking(1.6)
                        .foregroundStyle(color)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    private func edgeLayer(_ edges: [MapLayout.Edge], size: CGSize) -> some View {
        let lines = edges.map { ($0.kind, screen(mapPoint($0.from)), screen(mapPoint($0.to))) }
        return Canvas { context, _ in
            for (kind, a, b) in lines {
                var path = Path()
                path.move(to: a)
                // A gentle curve reads better than straight spokes.
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - abs(a.x - b.x) * 0.08)
                path.addQuadCurve(to: b, control: mid)
                switch kind {
                case .parent:
                    context.stroke(path, with: .color(Theme.blue.opacity(0.45)), lineWidth: 1.5)
                case .link:
                    context.stroke(path, with: .color(Theme.violet.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: Gestures

    /// Drag to move. Drop onto another node to file it there (that node becomes its folder).
    private func nodeDrag(_ id: UUID, among items: [Item]) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let start = doc.positions[id] ?? .zero
                let p = CGPoint(x: start.x + value.translation.width / scale,
                                y: start.y + value.translation.height / scale)
                dragging[id] = p
                dropTarget = target(near: p, dragging: id, among: items)
            }
            .onEnded { _ in
                guard let p = dragging[id] else { return }
                if let folder = dropTarget, var item = store.items[id] {
                    item.parentID = folder
                    store.update(item)
                    // Settle just beside the folder rather than on top of it.
                    let anchor = doc.positions[folder] ?? p
                    doc.move(id, to: CGPoint(x: anchor.x + 40, y: anchor.y + 70))
                } else {
                    doc.move(id, to: p)
                }
                dragging[id] = nil
                dropTarget = nil
            }
    }

    /// The node under `point`, if filing into it is allowed (not itself, not one of its own sub-items).
    private func target(near point: CGPoint, dragging id: UUID, among items: [Item]) -> UUID? {
        items.lazy
            .filter { $0.id != id && !store.isDescendant($0.id, of: id) }
            .first { other in
                guard let q = doc.positions[other.id] else { return false }
                return abs(q.x - point.x) < 70 && abs(q.y - point.y) < 26
            }?.id
    }

    @ViewBuilder
    private func nodeMenu(_ item: Item) -> some View {
        Button {
            router.push(item.id)
        } label: {
            Label("Open", systemImage: "arrow.up.right")
        }
        if !locked, let parent = store.parent(of: item) {
            Button {
                var unfiled = item
                unfiled.parentID = nil
                store.update(unfiled)
            } label: {
                Label("Take out of “\(parent.title)”", systemImage: "folder.badge.minus")
            }
        }
        if item.status == .open || item.status == .someday {
            Button {
                store.start(item.id)
            } label: {
                Label("Start", systemImage: "play")
            }
        }
        if item.status == .done {
            Button {
                store.reopen(item.id)
            } label: {
                Label("Reopen", systemImage: "arrow.uturn.backward")
            }
        } else {
            Button {
                store.markDone(item.id)
            } label: {
                Label("Mark done", systemImage: "checkmark.circle")
            }
        }
    }

    private func panAndZoom(viewSize: CGSize) -> some Gesture {
        let pan = DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in baseOffset = offset }
        let zoom = MagnifyGesture()
            .onChanged { value in
                let newScale = min(2.5, max(0.25, baseScale * value.magnification))
                // Zoom around the middle of the screen.
                let c = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                let ratio = newScale / scale
                offset = CGSize(width: c.x - (c.x - offset.width) * ratio,
                                height: c.y - (c.y - offset.height) * ratio)
                scale = newScale
            }
            .onEnded { _ in
                baseScale = scale
                baseOffset = offset
            }
        return pan.simultaneously(with: zoom)
    }

    /// Centres once, as soon as there's a real screen size to centre in.
    private func centreIfNeeded(_ items: [Item], in size: CGSize) {
        guard !didCenter, size.width > 0, size.height > 0 else { return }
        fit(items, in: size)
        didCenter = true
    }

    /// Zooms and centres so every node is on screen.
    private func fit(_ items: [Item], in size: CGSize) {
        let points = items.compactMap { doc.positions[$0.id] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            scale = 1
            offset = CGSize(width: size.width / 2, height: size.height / 2)
            baseScale = scale
            baseOffset = offset
            return
        }
        // Leave room for node chips, and for the buttons at the bottom right.
        // On a half-folded iPhone Duo, fit into the larger side of the fold.
        let area = fitArea ?? CGRect(origin: .zero, size: size)
        let bounds = CGRect(x: minX - 110, y: minY - 60, width: maxX - minX + 220, height: maxY - minY + 120)
        let usable = CGSize(width: area.width - 24, height: max(120, area.height - 110))
        scale = min(1.2, max(0.3, min(usable.width / bounds.width, usable.height / bounds.height)))
        offset = CGSize(width: area.midX - bounds.midX * scale,
                        height: area.minY + (area.height - 80) / 2 - bounds.midY * scale)
        baseScale = scale
        baseOffset = offset
    }

    // MARK: Controls

    private func controls(_ items: [Item], edges: [MapLayout.Edge], size: CGSize) -> some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 10) {
                if !isScribbling {
                    mapButton(locked ? "lock.fill" : "lock.open", tint: locked ? Theme.pink : Theme.muted,
                              label: locked ? "Unlock editing" : "Lock editing", id: "lock", active: locked) {
                        withAnimation(.snappy) { locked.toggle() }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: locked)
                }
                if isScribbling {
                    mapButton("arrow.uturn.backward", tint: Theme.blue, label: "Undo", id: "undo") { scribble.undo() }
                        .disabled(!scribble.canUndo)
                        .opacity(scribble.canUndo ? 1 : 0.4)
                    mapButton("arrow.uturn.forward", tint: Theme.blue, label: "Redo", id: "redo") { scribble.redo() }
                        .disabled(!scribble.canRedo)
                        .opacity(scribble.canRedo ? 1 : 0.4)
                    if !doc.drawing.strokes.isEmpty {
                        mapButton("trash", tint: Theme.pink, label: "Clear scribbles", id: "clear") { scribble.clear() }
                    }
                }
                if !locked {
                    mapButton(isScribbling ? "hand.point.up.left" : "pencil.tip", tint: isScribbling ? Theme.pink : Theme.violet,
                              label: isScribbling ? "Done scribbling" : "Scribble", id: "pencil", active: isScribbling) {
                        withAnimation(.smooth(duration: 0.35)) { isScribbling.toggle() }
                    }
                }
                if !isScribbling && !locked {
                    mapButton("wand.and.stars", tint: Theme.violet, label: "Arrange", id: "arrange") {
                        withAnimation(.snappy) {
                            doc.tidy(items, edges: edges)
                            fit(items, in: size)
                        }
                    }
                }
                if !isScribbling {
                    mapButton("viewfinder", tint: Theme.blue, label: "Fit to screen", id: "fit") {
                        withAnimation(.snappy) { fit(items, in: size) }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: isScribbling)
        .animation(.smooth(duration: 0.35), value: locked)
        .padding(16)
    }

    /// A Liquid Glass circle. Interactive glass squishes and glows under your finger;
    /// a shared glass ID lets buttons morph as they appear and disappear.
    private func mapButton(_ icon: String, tint: Color, label: String, id: String, active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(active ? .regular.tint(tint.opacity(0.35)).interactive() : .regular.interactive(), in: .circle)
        .glassEffectID(id, in: glassSpace)
        .accessibilityLabel(label)
    }

    // MARK: iPhone Duo

    /// How far to lift the buttons so the stack never straddles the fold (or sits under a camera).
    static func controlsLift(_ geo: GeometryProxy) -> CGFloat {
        guard #available(iOS 27.1, *) else { return 0 }
        let regions = (geo.reservedRegions(kind: .division) + geo.reservedRegions(kind: .occlusion)).filter(\.isActive)
        guard !regions.isEmpty else { return 0 }
        let stackHeight: CGFloat = 4 * 46 + 3 * 10 + 32
        let w = geo.size.width, h = geo.size.height
        var lift: CGFloat = 0
        for region in regions {
            let stack = CGRect(x: w - 46 - 32, y: h - stackHeight - lift, width: 46 + 32, height: stackHeight)
            if region.frame.intersects(stack) {
                // Not enough room below it: sit just above it instead.
                lift = max(lift, h - region.frame.minY)
            }
        }
        return lift
    }

    /// The larger side of an active fold, or nil when the screen isn't divided.
    static func largerPane(_ proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *),
              let fold = proxy.reservedRegions(kind: .division).first(where: \.isActive)?.frame else { return nil }
        let size = proxy.size
        if fold.height > fold.width {
            // Folded like a book: left and right.
            let left = CGRect(x: 0, y: 0, width: fold.minX, height: size.height)
            let right = CGRect(x: fold.maxX, y: 0, width: size.width - fold.maxX, height: size.height)
            return left.width >= right.width ? left : right
        } else {
            // Folded like a laptop: top and bottom.
            let top = CGRect(x: 0, y: 0, width: size.width, height: fold.minY)
            let bottom = CGRect(x: 0, y: fold.maxY, width: size.width, height: size.height - fold.maxY)
            return top.height >= bottom.height ? top : bottom
        }
    }
}

/// A node: frosted chip, coloured by status. Folders (nodes with things filed in them)
/// are bigger and show a folder icon.
private struct MapNode: View {
    let item: Item
    let isFolder: Bool
    var isDropTarget = false
    private var isProject: Bool { isFolder }

    var body: some View {
        HStack(spacing: 8) {
            if isFolder {
                Image(systemName: "folder.fill").font(.caption).foregroundStyle(tint)
            } else {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .font(isProject ? .subheadline.weight(.semibold) : .footnote.weight(.medium))
                .lineLimit(2)
                .strikethrough(item.status == .done)
                .foregroundStyle(item.status == .done ? .secondary : .primary)
        }
        .padding(.horizontal, isProject ? 14 : 11)
        .padding(.vertical, isProject ? 10 : 7)
        .frame(maxWidth: 190)
        .nogPanel(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isDropTarget ? Theme.blue : tint.opacity(0.55), lineWidth: isDropTarget ? 2.5 : 1))
        .shadow(color: isDropTarget ? Theme.blue.opacity(0.6) : .clear, radius: 12)
        .scaleEffect(isDropTarget ? 1.08 : 1)
        .animation(.snappy, value: isDropTarget)
    }

    private var tint: Color {
        switch item.status {
        case .doing, .done: Theme.blue
        case .someday: Theme.violet
        case .open: item.reminder.map { $0.isActive(at: .now) ? Theme.pink : Theme.violet } ?? Theme.muted
        }
    }
}

// MARK: - Outline

/// Folders-and-files view: top-level items, with projects expanding into their sub-items.
struct OutlineView: View {
    @Environment(ItemStore.self) private var store
    let showNogged: Bool
    /// "" = All, otherwise only this tag's items (and what's filed under them).
    var page: String = ""

    struct Node: Identifiable {
        let item: Item
        var children: [Node]?
        var id: UUID { item.id }
    }

    @Environment(Router.self) private var router
    /// Collapsed folder ids, remembered between launches.
    @AppStorage("outlineCollapsed") private var collapsedRaw = ""
    static let unfiledID = UUID(uuidString: "00000000-0000-0000-0000-00000000F11E")!

    var body: some View {
        let roots = Self.tree(MapPage.items(Array(store.items.values), page: page, showNogged: showNogged),
                              showNogged: showNogged)
        let folders = roots.filter { $0.children != nil }
        let unfiled = roots.filter { $0.children == nil }

        List {
            // Every node with things connected under it on the map is a folder.
            ForEach(folders) { folder in
                Section(isExpanded: expanded(folder.id)) {
                    ForEach(folder.children ?? []) { child in
                        OutlineBranch(node: child, expanded: expanded)
                    }
                } header: {
                    FolderHeader(item: folder.item, count: Self.count(folder)) { router.push(folder.item.id) }
                }
            }
            if !unfiled.isEmpty {
                Section(isExpanded: expanded(Self.unfiledID)) {
                    ForEach(unfiled) { node in
                        OutlineBranch(node: node, expanded: expanded)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "tray").foregroundStyle(Theme.muted)
                        Text("UNFILED").font(.nogLabel).tracking(2).foregroundStyle(Theme.muted)
                        Text(String(format: "%02d", unfiled.count)).font(.nogMeta).foregroundStyle(Theme.muted.opacity(0.7))
                    }
                }
            }
        }
        .listStyle(.sidebar) // makes section headers collapsible
        .nogListStyle()
        .overlay {
            if roots.isEmpty {
                ContentUnavailableView("No items yet", systemImage: "folder",
                                       description: Text("On the map, drop a node onto another to file it there."))
            }
        }
    }

    private var collapsed: Set<UUID> {
        Set(collapsedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func expanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { isOpen in
                var set = collapsed
                if isOpen { set.remove(id) } else { set.insert(id) }
                collapsedRaw = set.map(\.uuidString).sorted().joined(separator: ",")
            })
    }

    /// Items inside a folder, at any depth.
    nonisolated static func count(_ node: Node) -> Int {
        (node.children ?? []).reduce(0) { $0 + 1 + count($1) }
    }

    nonisolated static func tree(_ items: [Item], showNogged: Bool) -> [Node] {
        let visible = items.filter { showNogged || $0.status != .done }
        let ids = Set(visible.map(\.id))
        var byParent: [UUID?: [Item]] = [:]
        for item in visible {
            let parent = item.parentID.flatMap { ids.contains($0) ? $0 : nil }
            byParent[parent, default: []].append(item)
        }
        func order(_ a: Item, _ b: Item) -> Bool {
            let rank: [ItemStatus: Int] = [.doing: 0, .open: 1, .someday: 2, .done: 3]
            if rank[a.status] != rank[b.status] { return rank[a.status]! < rank[b.status]! }
            return a.created < b.created
        }
        var visited = Set<UUID>()
        func build(_ parent: UUID?) -> [Node] {
            (byParent[parent] ?? []).sorted(by: order).compactMap { item in
                guard visited.insert(item.id).inserted else { return nil } // guards against cycles
                let children = build(item.id)
                return Node(item: item, children: children.isEmpty ? nil : children)
            }
        }
        var roots = build(nil)
        // Items stuck in a parent loop (A inside B inside A) still show up, at the top level.
        for item in visible.sorted(by: order) where !visited.contains(item.id) {
            visited.insert(item.id)
            let children = build(item.id)
            roots.append(Node(item: item, children: children.isEmpty ? nil : children))
        }
        return roots
    }
}

/// A row, or a collapsible sub-folder with its own rows.
private struct OutlineBranch: View {
    let node: OutlineView.Node
    let expanded: (UUID) -> Binding<Bool>

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: expanded(node.id)) {
                ForEach(children) { child in
                    AnyView(OutlineBranch(node: child, expanded: expanded))
                }
            } label: {
                NavigationLink(value: node.item.id) {
                    OutlineRow(item: node.item, childCount: OutlineView.count(node))
                }
            }
            .listRowBackground(Theme.glass)
        } else {
            NavigationLink(value: node.item.id) {
                OutlineRow(item: node.item, childCount: 0)
            }
            .listRowBackground(Theme.glass)
        }
    }
}

/// Section header for a top-level folder: tap the header to collapse, the arrow to open it.
private struct FolderHeader: View {
    let item: Item
    let count: Int
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.blue)
            Text(item.title.uppercased())
                .font(.nogLabel)
                .tracking(1.6)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(String(format: "%02d", count)).font(.nogMeta).foregroundStyle(Theme.muted)
            ForEach(item.tags.prefix(2), id: \.self) { tag in
                let pair = TagPalette.color(for: tag)
                Text("#\(tag)").font(.caption2.weight(.medium)).foregroundStyle(Color(light: pair.light, dark: pair.dark))
            }
            Spacer()
            Button(action: open) {
                Image(systemName: "arrow.up.right.circle").foregroundStyle(Theme.blue)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open \(item.title)")
        }
        .textCase(nil)
    }
}

private struct OutlineRow: View {
    let item: Item
    let childCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: childCount > 0 ? "folder" : icon)
                .foregroundStyle(childCount > 0 ? Theme.blue : tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .strikethrough(item.status == .done)
                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                if childCount > 0 || !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        if childCount > 0 {
                            Text("\(childCount) ITEMS").font(.nogMeta).foregroundStyle(Theme.muted)
                        }
                        ForEach(item.tags.prefix(3), id: \.self) { tag in
                            let pair = TagPalette.color(for: tag)
                            Text("#\(tag)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color(light: pair.light, dark: pair.dark))
                        }
                    }
                }
            }
        }
    }

    private var icon: String {
        switch item.status {
        case .done: "checkmark.circle"
        case .doing: "play.circle"
        case .someday: "moon.stars"
        case .open: item.reminder == nil ? "doc.text" : "bell"
        }
    }

    private var tint: Color {
        switch item.status {
        case .done, .doing: Theme.blue
        case .someday: Theme.violet
        case .open: item.reminder == nil ? Theme.muted : Theme.pink
        }
    }
}

/// All · #travel 6 · #admin 3 …: one page per tag, busiest first.
struct MapPageStrip: View {
    let tags: [(tag: String, count: Int)]
    let selected: String
    let select: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "ALL", count: nil, color: Theme.blue, isSelected: selected.isEmpty) { select("") }
                if tags.isEmpty {
                    Text("Add #tags to get a page per tag")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .padding(.leading, 4)
                }
                ForEach(tags, id: \.tag) { entry in
                    let pair = TagPalette.color(for: entry.tag)
                    chip(title: "#\(entry.tag.uppercased())", count: entry.count,
                         color: Color(light: pair.light, dark: pair.dark),
                         isSelected: selected == entry.tag) { select(entry.tag) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.edge).frame(height: 1) }
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func chip(title: String, count: Int?, color: Color, isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.nogLabel).tracking(1.4)
                if let count {
                    Text("\(count)").font(.nogMeta).opacity(0.7)
                }
            }
            .foregroundStyle(isSelected ? color : Theme.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(color.opacity(isSelected ? 0.12 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? color.opacity(0.7) : Theme.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
