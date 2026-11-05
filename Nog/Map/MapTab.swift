import PencilKit
import SwiftUI

/// See your data: a draggable mind map (with tag zones and scribbling) or an
/// Obsidian-style outline of projects and their sub-items.
struct MapTab: View {
    enum Mode: String, CaseIterable { case map = "Map", outline = "Outline" }

    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @State private var mode: Mode = .map
    @State private var doc = MapDocument()
    @State private var showNogged = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.mapPath) {
            Group {
                switch mode {
                case .map: MindMapView(doc: doc, showNogged: showNogged)
                case .outline: OutlineView(showNogged: showNogged)
                }
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
        .task(id: store.folder) { doc.load(from: store) }
    }
}

// MARK: - Mind map

struct MindMapView: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @Bindable var doc: MapDocument
    let showNogged: Bool

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var didCenter = false
    @State private var isScribbling = false
    @State private var dragging: [UUID: CGPoint] = [:]
    /// The node a dragged node would be filed into if dropped now.
    @State private var dropTarget: UUID?

    /// The map's virtual canvas; (0, 0) in layout space is its centre.
    static let world = CGSize(width: 4000, height: 4000)
    private var origin: CGPoint { CGPoint(x: Self.world.width / 2, y: Self.world.height / 2) }

    var body: some View {
        let items = store.items.values
            .filter { showNogged || $0.status != .done }
            .sorted { $0.created < $1.created }
        let edges = MapLayout.edges(for: items)
        let hasChildren = Set(items.compactMap(\.parentID))

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    zones(items)
                    edgeLayer(edges)
                    ForEach(items) { item in
                        MapNode(item: item, isFolder: hasChildren.contains(item.id), isDropTarget: dropTarget == item.id)
                            .position(worldPoint(item.id))
                            .gesture(nodeDrag(item.id, among: items))
                            .onTapGesture { router.push(item.id) }
                            .contextMenu { nodeMenu(item) }
                            .allowsHitTesting(!isScribbling)
                    }
                    ScribbleCanvas(drawing: doc.drawing, isActive: isScribbling) { doc.setDrawing($0) }
                        .frame(width: Self.world.width, height: Self.world.height)
                        .allowsHitTesting(isScribbling)
                }
                .frame(width: Self.world.width, height: Self.world.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(offset)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(panAndZoom(viewSize: geo.size), including: isScribbling ? .subviews : .all)
            .onAppear {
                doc.placeMissing(items, edges: edges)
                if !didCenter { fit(items, in: geo.size); didCenter = true }
            }
            .onChange(of: items.map(\.id)) { doc.placeMissing(items, edges: edges) }
            .overlay(alignment: .bottomTrailing) { controls(items, edges: edges, size: geo.size) }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Nothing to map yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Capture a few things, give them #tags, sub-items or [[links]], and they'll show up here."))
                }
            }
        }
    }

    // MARK: Layers

    private func worldPoint(_ id: UUID) -> CGPoint {
        let p = dragging[id] ?? doc.positions[id] ?? .zero
        return CGPoint(x: origin.x + p.x, y: origin.y + p.y)
    }

    private struct Zone: Identifiable {
        let tag: String
        let rect: CGRect
        var id: String { tag }
    }

    /// One soft, coloured zone per #tag, wrapped around its items.
    @ViewBuilder
    private func zones(_ items: [Item]) -> some View {
        let zones: [Zone] = {
            var byTag: [String: [CGPoint]] = [:]
            for item in items {
                for tag in item.tags { byTag[tag.lowercased(), default: []].append(worldPoint(item.id)) }
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
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(color.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
                .overlay(alignment: .topLeading) {
                    Text("#\(zone.tag.uppercased())")
                        .font(.nogLabel)
                        .tracking(1.6)
                        .foregroundStyle(color)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                .frame(width: zone.rect.width, height: zone.rect.height)
                .position(x: zone.rect.midX, y: zone.rect.midY)
                .allowsHitTesting(false)
        }
    }

    private func edgeLayer(_ edges: [MapLayout.Edge]) -> some View {
        let lines = edges.map { ($0.kind, worldPoint($0.from), worldPoint($0.to)) }
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
        .frame(width: Self.world.width, height: Self.world.height)
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
        if let parent = store.parent(of: item) {
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

    /// Zooms and centres so every node is on screen.
    private func fit(_ items: [Item], in size: CGSize) {
        let points = items.map { worldPoint($0.id) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            scale = 1
            offset = CGSize(width: size.width / 2 - origin.x, height: size.height / 2 - origin.y)
            baseScale = scale
            baseOffset = offset
            return
        }
        let bounds = CGRect(x: minX - 120, y: minY - 80, width: maxX - minX + 240, height: maxY - minY + 160)
        scale = min(1.2, max(0.3, min(size.width / bounds.width, size.height / bounds.height)))
        offset = CGSize(width: size.width / 2 - bounds.midX * scale, height: size.height / 2 - bounds.midY * scale)
        baseScale = scale
        baseOffset = offset
    }

    // MARK: Controls

    private func controls(_ items: [Item], edges: [MapLayout.Edge], size: CGSize) -> some View {
        VStack(spacing: 10) {
            if isScribbling && !doc.drawing.strokes.isEmpty {
                mapButton("trash", tint: Theme.pink, label: "Clear scribbles") { doc.setDrawing(PKDrawing()) }
            }
            mapButton(isScribbling ? "hand.point.up.left" : "pencil.tip", tint: isScribbling ? Theme.pink : Theme.violet,
                      label: isScribbling ? "Done scribbling" : "Scribble") {
                isScribbling.toggle()
            }
            if !isScribbling {
                mapButton("wand.and.stars", tint: Theme.violet, label: "Tidy layout") {
                    withAnimation(.snappy) { doc.tidy(items, edges: edges) }
                }
                mapButton("viewfinder", tint: Theme.blue, label: "Fit to screen") {
                    withAnimation(.snappy) { fit(items, in: size) }
                }
            }
        }
        .padding(16)
    }

    private func mapButton(_ icon: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        let roots = Self.tree(Array(store.items.values), showNogged: showNogged)
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
