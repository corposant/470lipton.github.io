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

/// The map. Tap a chip to select it (it lights up and its details slide up from
/// the bottom); tap it again to open it. Only a selected chip can be dragged; a drag
/// that starts anywhere else pans, so nothing moves by accident.
struct MindMapView: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var isZooming = false
    @State private var didCenter = false
    /// Set once you pan or zoom. Until then the map keeps itself fitted when the
    /// screen changes size (rotation, split view, the page strip settling).
    @State private var viewMoved = false
    @State private var isScribbling = false
    /// Worked-out items, lines and zones, rebuilt only when the items change.
    @State private var cache = MapGraphCache()
    /// Each chip's real size, for layouts.
    @State private var chipSizes = ChipSizes()
    /// Chips flocking to new spots after the wand (nil when nothing is moving).
    @State private var flight: MapFlight?
    /// The chip that's lit up, with its details card showing.
    @State private var selection: UUID?
    /// The selected chip while it's being dragged, and where it is now (map coordinates).
    @State private var drag: NodeDrag?
    /// The chip a dragged chip is hovering over (not filed yet).
    @State private var dropCandidate: UUID?
    /// The chip it will be filed into if dropped now: armed after a short hold.
    @State private var dropTarget: UUID?
    @State private var dwell: Task<Void, Never>?
    /// "Moved · Undo": the last change, until you dismiss it or make another.
    @State private var notice: MapNotice?
    /// The item whose "File into…" list is showing (VoiceOver and the card).
    @State private var filing: UUID?
    @State private var scribble = ScribbleController()
    /// Locked: nodes can't be moved or filed, no scribbling or tidying (pan/zoom/tap/select still work).
    @AppStorage("mapLocked") private var locked = false
    /// Lets the Liquid Glass buttons morph into each other as the set changes.
    @Namespace private var glassSpace
    /// On a half-folded iPhone Duo, the larger side of the fold (Fit centres there).
    @State private var fitArea: CGRect?

    private struct NodeDrag {
        let id: UUID
        var point: CGPoint
    }

    /// How long a dragged chip has to hover over another before dropping files it there.
    private static let fileHold: Duration = .milliseconds(500)

    var body: some View {
        let graph = cache.graph(store.items, page: page, showNogged: showNogged)
        let selected = selection.flatMap { graph.byID[$0] }

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Scribbles sit underneath everything else. While scribbling, the nodes
                // ignore touches, so strokes reach this layer even where they pass under a node.
                ScribbleCanvas(drawing: doc.drawing, drawingVersion: doc.drawingVersion,
                               transform: viewTransform, isZooming: isZooming,
                               isActive: isScribbling, controller: scribble) { doc.setDrawing($0) }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(isScribbling)
                // Tapping empty space clears the selection.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onTapGesture { select(nil, in: geo.size) }
                    .allowsHitTesting(!isScribbling)
                    .accessibilityHidden(true)
                let zones = zoneList(graph)
                zoneFills(zones)
                edgeLayer(graph.edges, focus: selected?.id, size: geo.size)
                // Zone titles sit on the zone's top border, above the lines, below the chips.
                zoneLabels(zones)
                ForEach(graph.items) { item in
                    // A new item appears once it has a spot (worked out off the main thread).
                    if placedPoint(item.id) != nil {
                        node(item, graph: graph, size: geo.size)
                    }
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
                    doc.seedIfEmpty(from: seed, ids: graph.ids)
                }
                doc.refreshFromDisk()
                place(graph, thenCentreIn: geo.size)
            }
            .onChange(of: geo.size) {
                if didCenter && !viewMoved { fit(graph.items, in: geo.size) }
                centreIfNeeded(graph.items, in: geo.size)
            }
            // Re-centre every time the map opens, once layout has settled.
            .onDisappear {
                didCenter = false
                viewMoved = false
                cancelDrag()
            }
            .task {
                await Task.yield()
                centreIfNeeded(graph.items, in: geo.size)
            }
            .onChange(of: graph.ids) {
                // Another device may have placed the new items already.
                doc.refreshFromDisk()
                place(graph, thenCentreIn: geo.size)
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active { doc.refreshFromDisk() }
            }
            .onChange(of: isScribbling) {
                // Scribbling clears the undo history, and nothing is selected meanwhile.
                if isScribbling {
                    selection = nil
                    notice = nil
                }
            }
            .onGeometryChange(for: CGRect?.self) { proxy in Self.largerPane(proxy) } action: { fitArea = $0 }
            .overlay(alignment: .bottomTrailing) {
                controls(graph, size: geo.size)
                    .padding(.bottom, Self.controlsLift(geo))
                    .nogAnimation(.smooth, value: Self.controlsLift(geo))
            }
            .overlay(alignment: .bottomLeading) {
                if let selected, !isScribbling {
                    MapInfoCard(item: selected,
                                parent: store.parent(of: selected),
                                progress: graph.progress[selected.id],
                                links: linkedTitles(selected, graph: graph),
                                isPinned: doc.pinned.contains(selected.id),
                                locked: locked,
                                canFile: graph.items.count > 1,
                                open: { router.push(selected.id) },
                                takeOut: { takeOut(selected.id) },
                                fileInto: { filing = selected.id },
                                unpin: { unpin(selected.id) },
                                close: { select(nil, in: geo.size) })
                        .frame(maxWidth: 460, alignment: .leading)
                        // Leave the button column on the right clear.
                        .padding(.leading, 12)
                        .padding(.trailing, 46 + 16 + 12)
                        .padding(.bottom, 16 + Self.controlsLift(geo))
                        .transition(.nog(.move(edge: .bottom).combined(with: .opacity)))
                        .id(selected.id)
                }
            }
            .overlay(alignment: .top) {
                if let notice {
                    MapNoticeBanner(notice: notice, undo: undoLast) {
                        withNogAnimation(.snappy) { self.notice = nil }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                    .transition(.nog(.move(edge: .top).combined(with: .opacity)))
                }
            }
            .overlay {
                if graph.items.isEmpty {
                    ContentUnavailableView("Nothing to map yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Capture a few things, give them #tags, sub-items or [[links]], and they'll show up here."))
                }
            }
            .confirmationDialog(filingTitle(graph), isPresented: filingShown, titleVisibility: .visible) {
                if let id = filing {
                    ForEach(graph.filingTargets(for: id, isDescendant: { store.isDescendant($0, of: $1) })) { target in
                        Button(Self.name(target)) { file(id, into: target.id) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .nogFeedback(.selection, trigger: selection)
            .nogFeedback(.impact(weight: .medium), trigger: dropTarget) { _, new in new != nil }
        }
    }

    // MARK: Nodes

    private func node(_ item: Item, graph: MapGraph, size: CGSize) -> some View {
        let isSelected = selection == item.id
        let canMove = isSelected && !locked && !isScribbling
        // With something selected, chips not joined to it fade back a little.
        let isDimmed = selection.map { $0 != item.id && !(graph.neighbours[$0]?.contains(item.id) ?? false) } ?? false
        let chip = chipFit
        return MapNode(item: item, isFolder: graph.folders.contains(item.id),
                       isSelected: isSelected, isDimmed: isDimmed,
                       isDropCandidate: dropCandidate == item.id && dropTarget != item.id,
                       isDropTarget: dropTarget == item.id,
                       subItems: graph.progress[item.id],
                       maxWidth: chip.maxWidth, compact: chip.compact)
            // Measured at full size only: a zoomed-out compact chip isn't its real size.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { measured in
                guard !chip.compact else { return }
                chipSizes.record(item.id, measured) { settle(graph) }
            }
            .scaleEffect(chip.scale)
            // Before .position, so VoiceOver's outline hugs the chip, not the whole map.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel(item, graph: graph))
            .accessibilityHint(isSelected ? "Double-tap to open." : "Double-tap to select.")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { tap(item.id, in: size) }
            .accessibilityActions { nodeActions(item, graph: graph) }
            .position(screen(mapPoint(item.id)))
            // Only the selected chip can be dragged. Anywhere else, a drag pans the map.
            .gesture(nodeDrag(item.id, graph: graph), including: canMove ? .all : .none)
            .onTapGesture { tap(item.id, in: size) }
            .contextMenu { nodeMenu(item) }
            .allowsHitTesting(!isScribbling)
            .zIndex(isSelected ? 1 : 0)
    }

    /// First tap selects, second tap opens.
    private func tap(_ id: UUID, in size: CGSize) {
        if selection == id {
            router.push(id)
        } else {
            select(id, in: size)
        }
    }

    private func select(_ id: UUID?, in size: CGSize) {
        guard id != selection else { return }
        withNogAnimation(.snappy) { selection = id }
        if let id { reveal(id, in: size) }
    }

    /// Pans so a newly selected chip isn't hidden under its details card or off screen.
    private func reveal(_ id: UUID, in size: CGSize) {
        guard let p = doc.positions[id] else { return }
        let s = screen(p)
        let cardTop = size.height - 260
        let margin: CGFloat = 60
        guard s.y > cardTop || s.y < margin || s.x < margin || s.x > size.width - margin else { return }
        let goal = CGPoint(x: min(max(s.x, margin + 40), size.width - margin - 40), y: max(margin + 40, size.height * 0.35))
        viewMoved = true
        withNogAnimation(.smooth) {
            offset = CGSize(width: offset.width + goal.x - s.x, height: offset.height + goal.y - s.y)
            baseOffset = offset
        }
    }

    private static func name(_ item: Item) -> String {
        item.title.isEmpty ? "Untitled" : item.title
    }

    private func linkedTitles(_ item: Item, graph: MapGraph) -> [String] {
        (graph.neighbours[item.id] ?? [])
            .compactMap { graph.byID[$0] }
            .filter { $0.id != item.parentID && $0.parentID != item.id }
            .map(Self.name)
            .sorted()
    }

    /// What VoiceOver reads for a chip. Only worked out in full while VoiceOver is on,
    /// since it's rebuilt for every chip on every pan frame.
    private func spokenLabel(_ item: Item, graph: MapGraph) -> String {
        guard voiceOverOn else { return Self.name(item) }
        var parts = [Self.name(item), item.status.label]
        if let parent = store.parent(of: item) { parts.append("in \(Self.name(parent))") }
        let progress = graph.progress[item.id]
        if progress.total > 0 { parts.append("\(progress.done) of \(progress.total) sub-items done") }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#\($0)" }.joined(separator: " ")) }
        if let next = item.effectiveReminder?.nextFire(after: .now) {
            parts.append("next nog \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        let links = linkedTitles(item, graph: graph).count
        if links > 0 { parts.append(links == 1 ? "1 link" : "\(links) links") }
        if doc.pinned.contains(item.id) { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }

    /// VoiceOver and Switch Control: everything a drag can do, without dragging.
    @ViewBuilder
    private func nodeActions(_ item: Item, graph: MapGraph) -> some View {
        Button("Open") { router.push(item.id) }
        if !locked {
            Button("Move left") { nudge(item.id, dx: -1, dy: 0, direction: "left") }
            Button("Move right") { nudge(item.id, dx: 1, dy: 0, direction: "right") }
            Button("Move up") { nudge(item.id, dx: 0, dy: -1, direction: "up") }
            Button("Move down") { nudge(item.id, dx: 0, dy: 1, direction: "down") }
            if graph.items.count > 1 {
                Button("File into…") { filing = item.id }
            }
            if let parent = store.parent(of: item) {
                Button("Take out of \(Self.name(parent))") { takeOut(item.id) }
            }
            if doc.pinned.contains(item.id) {
                Button("Unpin") { unpin(item.id) }
            }
        }
        if item.status == .open || item.status == .someday {
            Button("Start") { store.start(item.id) }
        }
        if item.status == .done {
            Button("Reopen") { store.reopen(item.id) }
        } else {
            Button("Mark done") { store.markDone(item.id) }
        }
    }

    // MARK: Coordinates

    private var viewTransform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.width, ty: offset.height)
    }

    private func mapPoint(_ id: UUID) -> CGPoint {
        placedPoint(id) ?? .zero
    }

    /// Where a chip is, or nil while it hasn't been placed yet.
    private func placedPoint(_ id: UUID) -> CGPoint? {
        if let drag, drag.id == id { return drag.point }
        if let flight, let p = flight.positions[id] { return p }
        return doc.positions[id]
    }

    /// How big chips are drawn at this zoom. Below about 55% they stop shrinking so
    /// titles stay readable, but they also get narrower (one line) so they still fit
    /// between their neighbours instead of piling up.
    private var chipFit: (scale: CGFloat, maxWidth: CGFloat, compact: Bool) {
        let chipScale = min(1.15, max(0.55, scale))
        // Room between neighbouring standard spots, in the chip's own (unscaled) points.
        let room = MapLayout.pitch.width * scale / chipScale - 16
        return room < 190 ? (chipScale, max(56, room), true) : (chipScale, 190, false)
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
        /// Tags that wrap exactly these items (usually one).
        let tags: [String]
        let members: Set<UUID>
        var rect: CGRect // map coordinates
        var id: String { tags.joined(separator: "+") }
        var label: String { tags.map { "#" + $0.uppercased() }.joined(separator: " · ") }
        var color: Color {
            let pair = TagPalette.color(for: tags[0])
            return Color(light: pair.light, dark: pair.dark)
        }
    }

    /// Room around the chips inside a zone: extra on top for the title tab on the border.
    private static let zoneInset = (side: MapLayout.cell.width / 2 + 26, top: MapLayout.cell.height / 2 + 42,
                                    bottom: MapLayout.cell.height / 2 + 26)

    /// One soft, coloured zone per #tag, wrapped around its items.
    private func zoneList(_ graph: MapGraph) -> [Zone] {
        let inset = Self.zoneInset
        // The groups come smallest first, so each zone can grow around the ones nested
        // inside it: borders never coincide and the titles stack instead of overprinting.
        var zones: [Zone] = graph.zoneGroups.compactMap { group in
            let points = group.members.compactMap(placedPoint)
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
            let rect = CGRect(x: minX - inset.side, y: minY - inset.top,
                              width: maxX - minX + 2 * inset.side, height: maxY - minY + inset.top + inset.bottom)
            return Zone(tags: group.tags, members: group.members, rect: rect)
        }
        for j in zones.indices {
            for i in zones.indices where i < j && zones[i].members.isStrictSubset(of: zones[j].members) {
                let inner = zones[i].rect
                zones[j].rect = zones[j].rect.union(CGRect(x: inner.minX - 18, y: inner.minY - 32,
                                                           width: inner.width + 36, height: inner.height + 50))
            }
        }
        // Biggest drawn first (underneath).
        return zones.reversed()
    }

    private func zoneFills(_ zones: [Zone]) -> some View {
        ForEach(zones) { zone in
            let r = screen(zone.rect)
            RoundedRectangle(cornerRadius: 32 * scale, style: .continuous)
                .fill(zone.color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 32 * scale, style: .continuous)
                    .strokeBorder(zone.color.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
                .frame(width: max(1, r.width), height: max(1, r.height))
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    /// Each zone's title as a tab sitting on its top border, outside the chips' space,
    /// on a solid backing so lines passing underneath don't cut through it.
    private func zoneLabels(_ zones: [Zone]) -> some View {
        ForEach(zones) { zone in
            let r = screen(zone.rect)
            Color.clear
                .frame(width: max(1, r.width), height: max(1, r.height))
                .overlay(alignment: .topLeading) {
                    Text(zone.label)
                        .font(.nogLabel)
                        .tracking(1.6)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(zone.color)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Theme.base, in: Capsule())
                        .overlay(Capsule().strokeBorder(zone.color.opacity(0.6), lineWidth: 1))
                        // Centred on the border line, a little in from the corner.
                        .alignmentGuide(.top) { $0.height / 2 }
                        .alignmentGuide(.leading) { _ in -max(14, 30 * scale) }
                }
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    /// Lines between chips. With a chip selected, its own lines get stronger and the rest fade.
    private func edgeLayer(_ edges: [MapLayout.Edge], focus: UUID?, size: CGSize) -> some View {
        let lines = edges.compactMap { edge -> (kind: MapLayout.Edge.Kind, a: CGPoint, b: CGPoint, emphasis: Double)? in
            guard let from = placedPoint(edge.from), let to = placedPoint(edge.to) else { return nil }
            return (kind: edge.kind, a: screen(from), b: screen(to),
                    emphasis: focus.map { $0 == edge.from || $0 == edge.to ? 1.6 : 0.45 } ?? 1.0)
        }
        return Canvas { context, _ in
            for line in lines {
                var path = Path()
                path.move(to: line.a)
                // A gentle curve reads better than straight spokes.
                let mid = CGPoint(x: (line.a.x + line.b.x) / 2, y: (line.a.y + line.b.y) / 2 - abs(line.a.x - line.b.x) * 0.08)
                path.addQuadCurve(to: line.b, control: mid)
                let e = line.emphasis
                switch line.kind {
                case .parent:
                    context.stroke(path, with: .color(Theme.blue.opacity(min(1, 0.45 * e))), lineWidth: 1.5 * max(1, e))
                case .link:
                    context.stroke(path, with: .color(Theme.violet.opacity(min(1, 0.6 * e))),
                                   style: StrokeStyle(lineWidth: 1.2 * max(1, e), dash: [5, 5]))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: Moving and filing

    /// Drags the selected chip. Hover over another chip for a moment, then let go, to file it there.
    private func nodeDrag(_ id: UUID, graph: MapGraph) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if flight != nil { landNow() }
                let start = doc.positions[id] ?? .zero
                let p = CGPoint(x: start.x + value.translation.width / scale,
                                y: start.y + value.translation.height / scale)
                drag = NodeDrag(id: id, point: p)
                hover(over: target(near: p, dragging: id, graph: graph))
            }
            .onEnded { _ in finishDrag(id) }
    }

    /// Arms filing only after the chip has hovered over the same target for a moment,
    /// so sliding past a chip on the way somewhere else never files anything.
    private func hover(over candidate: UUID?) {
        guard candidate != dropCandidate else { return }
        dropCandidate = candidate
        dropTarget = nil
        dwell?.cancel()
        guard let candidate else { return }
        dwell = Task { @MainActor in
            try? await Task.sleep(for: Self.fileHold)
            guard !Task.isCancelled, dropCandidate == candidate else { return }
            withNogAnimation(.snappy) { dropTarget = candidate }
        }
    }

    private func finishDrag(_ id: UUID) {
        defer { cancelDrag() }
        guard let drag, drag.id == id else { return }
        if let folder = dropTarget {
            file(id, into: folder)
        } else {
            guard let item = store.items[id] else { return }
            perform(MapChange(spots: [.init(id: id, position: drag.point)], pins: [.init(id: id, pinned: true)]),
                    message: "Moved “\(Self.name(item))”")
        }
    }

    private func cancelDrag() {
        dwell?.cancel()
        dwell = nil
        drag = nil
        dropCandidate = nil
        dropTarget = nil
    }

    /// The node under `point`, if filing into it is allowed (not itself, not one of its own sub-items).
    private func target(near point: CGPoint, dragging id: UUID, graph: MapGraph) -> UUID? {
        graph.items.lazy
            .filter { $0.id != id && !store.isDescendant($0.id, of: id) }
            .first { other in
                guard let q = doc.positions[other.id] else { return false }
                // The middle three quarters of the target chip, so brushing its edge doesn't count.
                let s = MapLayout.size(other.id, in: chipSizes.sizes)
                return abs(q.x - point.x) < s.width * 0.375 && abs(q.y - point.y) < s.height * 0.375
            }?.id
    }

    private func file(_ id: UUID, into folder: UUID) {
        guard let item = store.items[id], let target = store.items[folder],
              folder != id, !store.isDescendant(folder, of: id) else { return }
        // Settle just beside the folder rather than on top of it.
        let anchor = doc.positions[folder] ?? doc.positions[id] ?? .zero
        perform(MapChange(spots: [.init(id: id, position: CGPoint(x: anchor.x + 40, y: anchor.y + 70))],
                          filings: [.init(id: id, parent: folder)],
                          pins: [.init(id: id, pinned: true)]),
                message: "Filed “\(Self.name(item))” in “\(Self.name(target))”")
    }

    /// Lets Tidy up move a chip you placed by hand.
    private func unpin(_ id: UUID) {
        guard let item = store.items[id] else { return }
        perform(MapChange(pins: [.init(id: id, pinned: false)]), message: "Unpinned “\(Self.name(item))”")
    }

    private func takeOut(_ id: UUID) {
        guard let item = store.items[id], let parent = store.parent(of: item) else { return }
        perform(MapChange(filings: [.init(id: id, parent: nil)]),
                message: "Took “\(Self.name(item))” out of “\(Self.name(parent))”")
    }

    /// Moves a chip one step (VoiceOver, Switch Control).
    private func nudge(_ id: UUID, dx: CGFloat, dy: CGFloat, direction: String) {
        guard let item = store.items[id], let p = doc.positions[id] else { return }
        let to = CGPoint(x: p.x + dx * MapLayout.pitch.width / 2, y: p.y + dy * MapLayout.pitch.height)
        perform(MapChange(spots: [.init(id: id, position: to)], pins: [.init(id: id, pinned: true)]),
                message: "Moved “\(Self.name(item))” \(direction)")
    }

    // MARK: Undo

    /// Makes a change, makes it undoable, and says what happened.
    private func perform(_ change: MapChange, message: String) {
        guard !change.isEmpty else { return }
        let undo = doc.apply(change, store: store)
        if let undoManager {
            Self.registerUndo(undo, doc: doc, store: store, manager: undoManager, name: message)
        }
        withNogAnimation(.snappy) { notice = MapNotice(message: message, undo: undo) }
        AccessibilityNotification.Announcement(message).post()
    }

    /// Registers `change` as the undo; undoing registers its opposite as the redo.
    private static func registerUndo(_ change: MapChange, doc: MapDocument, store: ItemStore,
                                     manager: UndoManager, name: String) {
        manager.registerUndo(withTarget: doc) { doc in
            MainActor.assumeIsolated {
                let opposite = doc.apply(change, store: store)
                registerUndo(opposite, doc: doc, store: store, manager: manager, name: name)
            }
        }
        manager.setActionName(name)
    }

    /// The banner's Undo: the same as the system undo (shake, three-finger swipe, ⌘Z).
    private func undoLast() {
        guard let notice else { return }
        if let undoManager, undoManager.canUndo {
            undoManager.undo()
        } else {
            doc.apply(notice.undo, store: store)
        }
        withNogAnimation(.snappy) { self.notice = nil }
        AccessibilityNotification.Announcement("Undone").post()
    }

    // MARK: Menus

    private var filingShown: Binding<Bool> {
        Binding(get: { filing != nil }, set: { if !$0 { filing = nil } })
    }

    private func filingTitle(_ graph: MapGraph) -> String {
        guard let id = filing, let item = graph.byID[id] else { return "File into…" }
        return "File “\(Self.name(item))” into…"
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
                takeOut(item.id)
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
                viewMoved = true
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in baseOffset = offset }
        let zoom = MagnifyGesture()
            .onChanged { value in
                if !isZooming { isZooming = true }
                viewMoved = true
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
                isZooming = false
            }
        return pan.simultaneously(with: zoom)
    }

    /// Centres once, as soon as there's a real screen size and every chip has a spot.
    private func centreIfNeeded(_ items: [Item], in size: CGSize) {
        guard !didCenter, size.width > 0, size.height > 0 else { return }
        // Wait until every chip has a spot: new chips are placed off the main thread, and
        // fitting before they land would centre on only the ones that were saved.
        // `place` calls this again once they have.
        guard items.allSatisfy({ doc.positions[$0.id] != nil }) else { return }
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
        // On a half-folded iPhone Duo, fit into the larger side of the fold.
        let area = fitArea ?? CGRect(origin: .zero, size: size)
        // Positions are chip centres. Chips are drawn at about their own size however far
        // you zoom out (see chipFit), so the room for half a chip each side is in screen
        // points, not map points. A margin in map points shrinks with the zoom and lets
        // the outer chips hang off the screen.
        let span = CGSize(width: max(1, maxX - minX), height: max(1, maxY - minY))
        let room = CGSize(width: area.width - 24, height: max(120, area.height - 110))
        var fitted: CGFloat = 1
        for _ in 0..<3 {
            let chipScale = min(1.15, max(0.55, fitted))
            let half = CGSize(width: 100 * chipScale, height: 30 * chipScale)
            let usable = CGSize(width: max(60, room.width - 2 * half.width),
                                height: max(60, room.height - 2 * half.height))
            fitted = min(1.2, max(0.3, min(usable.width / span.width, usable.height / span.height)))
        }
        scale = fitted
        viewMoved = false
        offset = CGSize(width: area.midX - (minX + maxX) / 2 * scale,
                        height: area.minY + (area.height - 80) / 2 - (minY + maxY) / 2 * scale)
        baseScale = scale
        baseOffset = offset
    }

    // MARK: Controls

    private func controls(_ graph: MapGraph, size: CGSize) -> some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 10) {
                if !isScribbling {
                    mapButton(locked ? "lock.fill" : "lock.open", tint: locked ? Theme.pink : Theme.muted,
                              label: locked ? "Unlock editing" : "Lock editing", id: "lock", active: locked) {
                        withNogAnimation(.snappy) { locked.toggle() }
                    }
                    .nogFeedback(.impact(weight: .light), trigger: locked)
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
                        withNogAnimation(.smooth(duration: 0.35)) { isScribbling.toggle() }
                    }
                }
                if !isScribbling && !locked {
                    wandButton(graph, size: size)
                }
                if !isScribbling {
                    mapButton("viewfinder", tint: Theme.blue, label: "Fit to screen", id: "fit") {
                        withNogAnimation(.snappy) { fit(graph.items, in: size) }
                    }
                }
            }
        }
        .nogAnimation(.smooth(duration: 0.35), value: isScribbling)
        .nogAnimation(.smooth(duration: 0.35), value: locked)
        .padding(16)
    }

    // MARK: The wand

    /// Tap: tidy up (keeps your arrangement). Touch and hold: a whole-page layout.
    private func wandButton(_ graph: MapGraph, size: CGSize) -> some View {
        Menu {
            Button {
                rearrange(graph, style: nil, in: size)
            } label: {
                Label("Tidy up", systemImage: "wand.and.stars")
                Text("Fixes overlaps, keeps your layout")
            }
            Section("Lay out as") {
                ForEach(MapLayout.Style.allCases) { style in
                    Button {
                        rearrange(graph, style: style, in: size)
                    } label: {
                        Label(style.title, systemImage: style.icon)
                        Text(style.detail)
                    }
                }
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.violet)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        } primaryAction: {
            rearrange(graph, style: nil, in: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("arrange", in: glassSpace)
        .accessibilityLabel("Tidy up")
        .accessibilityHint("Fixes overlaps and keeps your layout. More layouts in the actions.")
        .accessibilityActions {
            ForEach(MapLayout.Style.allCases) { style in
                Button("Lay out as \(style.title)") { rearrange(graph, style: style, in: size) }
            }
        }
    }

    /// Tidies up (style nil) or lays the page out in a style, then flocks the chips there.
    /// Undoable. A full layout also unpins everything, since it moves everything.
    private func rearrange(_ graph: MapGraph, style: MapLayout.Style?, in size: CGSize) {
        landNow()
        let items = graph.items, ids = graph.ids, sizes = chipSizes.sizes
        let current = doc.positions, pinned = doc.pinned
        let zones = graph.zoneGroups.map(\.members)
        Task {
            // Worked out off the main thread, so a big map doesn't freeze the screen.
            let targets = await Task.detached(priority: .userInitiated) { () -> [UUID: CGPoint] in
                if let style { return MapLayout.layOut(style, items: items, sizes: sizes) }
                return MapLayout.cleanup(items, positions: current, pinned: pinned, sizes: sizes, zones: zones)
            }.value
            let moved = ids.filter { id in
                guard let to = targets[id] else { return false }
                guard let from = current[id] else { return true }
                return abs(to.x - from.x) > 0.5 || abs(to.y - from.y) > 0.5
            }
            var change = MapChange(spots: moved.map { .init(id: $0, position: targets[$0]) })
            if style != nil {
                change.pins = ids.filter { pinned.contains($0) }.map { .init(id: $0, pinned: false) }
            }
            guard !change.isEmpty else {
                withNogAnimation(.snappy) { notice = nil }
                AccessibilityNotification.Announcement("Already tidy").post()
                return
            }
            let message: String
            if let style {
                message = "Laid out as \(style.title)"
            } else {
                message = moved.count == 1 ? "Tidied up 1 chip" : "Tidied up \(moved.count) chips"
            }
            perform(change, message: message)
            fly(from: current, to: targets, ids: moved, graph: graph)
            if style != nil {
                withNogAnimation(.smooth(duration: 0.8)) { fit(items, in: size) }
            }
        }
    }

    /// Flocks the chips that moved from where they were to their new spots.
    /// With Reduce Motion or Low stimulation they simply appear there.
    private func fly(from start: [UUID: CGPoint], to targets: [UUID: CGPoint], ids: [UUID], graph: MapGraph) {
        flight?.cancel()
        flight = nil
        guard !Calm.reducesMotion, !ids.isEmpty else { return }
        // Chips of the same project (or, if loose, the same tag zone) travel as a group.
        var groups: [UUID: Int] = [:]
        var rootIndex: [UUID: Int] = [:]
        for id in ids {
            var root = id
            var hops = 0
            while let parent = graph.byID[root]?.parentID, graph.byID[parent] != nil, hops < 32 {
                root = parent
                hops += 1
            }
            if rootIndex[root] == nil { rootIndex[root] = rootIndex.count }
            groups[id] = rootIndex[root]
        }
        let moving = Set(ids)
        let flock = MapFlock(from: start, to: targets.filter { moving.contains($0.key) }, groups: groups,
                             sizes: chipSizes.sizes)
        guard !flock.isEmpty else { return }
        let run = MapFlight(flock)
        flight = run
        run.start {
            if flight === run { flight = nil }
        }
    }

    /// Stops any flight: chips jump to where they're going.
    private func landNow() {
        flight?.cancel()
        flight = nil
    }

    /// Gives new items a spot (off the main thread), then centres the map if it hasn't been yet.
    private func place(_ graph: MapGraph, thenCentreIn size: CGSize) {
        let items = graph.items, edges = graph.edges, sizes = chipSizes.sizes
        Task {
            await doc.placeMissing(items, edges: edges, sizes: sizes)
            centreIfNeeded(items, in: size)
        }
    }

    /// Once chips have been measured, tidies any that were placed with a guessed size.
    private func settle(_ graph: MapGraph) {
        let ids = Set(graph.ids), sizes = chipSizes.sizes
        Task { await doc.settle(onPage: ids, sizes: sizes) }
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

/// The last change on the map, offered for undo.
struct MapNotice: Equatable {
    let id = UUID()
    let message: String
    /// Undoes it if the system undo isn't available.
    let undo: MapChange

    static func == (a: MapNotice, b: MapNotice) -> Bool { a.id == b.id }
}

/// "Moved “Hotel” · Undo". Stays until dismissed or replaced, so there's no rush.
private struct MapNoticeBanner: View {
    let notice: MapNotice
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(notice.message)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.blue)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 460)
        .nogPanel(cornerRadius: 18)
        .accessibilityElement(children: .contain)
    }
}

/// Details for the selected chip, at the bottom of the map.
private struct MapInfoCard: View {
    let item: Item
    let parent: Item?
    let progress: (done: Int, total: Int)
    /// Titles of items joined to this one by a [[link]].
    let links: [String]
    /// Placed by hand: Tidy up leaves it alone.
    let isPinned: Bool
    let locked: Bool
    let canFile: Bool
    let open: () -> Void
    let takeOut: () -> Void
    let fileInto: () -> Void
    let unpin: () -> Void
    let close: () -> Void
    @Environment(ItemStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.status.label.uppercased())
                        .font(.nogLabel)
                        .tracking(1.4)
                        .foregroundStyle(tint)
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.headline)
                        .lineLimit(3)
                        .strikethrough(item.status == .done)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deselect")
            }

            VStack(alignment: .leading, spacing: 5) {
                if let parent {
                    fact("folder", "In \(parent.title.isEmpty ? "Untitled" : parent.title)")
                }
                if progress.total > 0 {
                    fact("checklist", "\(progress.done) of \(progress.total) sub-items done")
                }
                if let next = item.effectiveReminder?.nextFire(after: .now) {
                    fact("bell", "Next nog \(next.formatted(date: .abbreviated, time: .shortened))")
                }
                if !links.isEmpty {
                    fact("link", "Linked to \(links.joined(separator: ", "))")
                }
                if isPinned {
                    fact("pin", "Pinned here: Tidy up leaves it alone")
                }
                if !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.tags.prefix(4), id: \.self) { tag in
                            let pair = TagPalette.color(for: tag)
                            Text("#\(tag)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color(light: pair.light, dark: pair.dark))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: open) {
                    Label("Open", systemImage: "arrow.up.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)

                if item.status == .done {
                    Button { store.reopen(item.id) } label: {
                        Label("Reopen", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { store.markDone(item.id) } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)
                }

                if !locked && (canFile || parent != nil || isPinned) || item.status == .open || item.status == .someday {
                    Menu {
                        if item.status == .open || item.status == .someday {
                            Button { store.start(item.id) } label: {
                                Label("Start", systemImage: "play")
                            }
                        }
                        if !locked && canFile {
                            Button(action: fileInto) {
                                Label("File into…", systemImage: "folder.badge.plus")
                            }
                        }
                        if !locked, let parent {
                            Button(action: takeOut) {
                                Label("Take out of “\(parent.title)”", systemImage: "folder.badge.minus")
                            }
                        }
                        if !locked && isPinned {
                            Button(action: unpin) {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 28, minHeight: 20)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("More actions")
                }
            }
            .font(.subheadline.weight(.medium))
            .tint(Theme.blue)
        }
        .padding(14)
        .nogPanel(cornerRadius: 20)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.blue.opacity(0.5), lineWidth: 1))
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).lineLimit(2)
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.muted)
        }
        .font(.subheadline)
    }

    private var tint: Color {
        switch item.status {
        case .doing, .done: Theme.blue
        case .someday: Theme.violet
        case .open: item.reminder.map { $0.isActive(at: .now) ? Theme.pink : Theme.violet } ?? Theme.muted
        }
    }
}

/// A node: frosted chip, coloured by status. Folders (nodes with things filed in them)
/// are bigger and show a folder icon. Selected: a thick outline and a check badge
/// (shape as well as colour). Dimmed: something else is selected.
private struct MapNode: View {
    let item: Item
    let isFolder: Bool
    var isSelected = false
    var isDimmed = false
    /// A dragged chip is hovering over this one, not long enough to file yet.
    var isDropCandidate = false
    /// Let go now and the dragged chip is filed here.
    var isDropTarget = false
    var subItems: (done: Int, total: Int) = (0, 0)
    /// Widest the chip may be, in its own (unzoomed) points.
    var maxWidth: CGFloat = 190
    /// Zoomed far out: one line and tighter padding, so chips still fit between neighbours.
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isProject: Bool { isFolder }

    var body: some View {
        HStack(spacing: 8) {
            if isFolder {
                // The folder sits inside a ring showing how many of its sub-items are done.
                Image(systemName: "folder.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if subItems.total > 0 {
                            ProgressRing(fraction: Double(subItems.done) / Double(subItems.total), tint: tint, lineWidth: 2)
                        }
                    }
            } else {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .font(isProject ? .subheadline.weight(.semibold) : .footnote.weight(.medium))
                .lineLimit(compact ? 1 : 2)
                .strikethrough(item.status == .done)
                .foregroundStyle(item.status == .done ? .secondary : .primary)
        }
        .padding(.horizontal, compact ? 8 : (isProject ? 14 : 11))
        .padding(.vertical, compact ? 5 : (isProject ? 10 : 7))
        .frame(maxWidth: maxWidth)
        .nogPanel(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(borderColor, style: StrokeStyle(lineWidth: borderWidth, dash: isDropCandidate ? [4, 3] : [])))
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white, Theme.blue)
                    .background(Circle().fill(Theme.base).padding(1))
                    .offset(x: 7, y: -7)
                    .transition(.nog(.scale.combined(with: .opacity)))
            }
        }
        .nogGlow(color: glow, radius: 12)
        // Lifting is motion: kept still with Reduce Motion (Low stimulation also drops the glow).
        .scaleEffect(reduceMotion ? 1 : (isDropTarget ? 1.08 : isSelected ? 1.04 : 1))
        // Stays well above 4.5:1 text contrast while dimmed.
        .opacity(isDimmed ? 0.7 : 1)
        .nogAnimation(.snappy, value: isDropTarget)
        .nogAnimation(.snappy, value: isSelected)
        .nogAnimation(.snappy, value: isDimmed)
    }

    private var borderColor: Color {
        if isDropTarget || isSelected || isDropCandidate { return Theme.blue }
        return tint.opacity(0.55)
    }

    private var borderWidth: CGFloat {
        if isDropTarget { return 3 }
        if isSelected { return 2.5 }
        if isDropCandidate { return 1.5 }
        return 1
    }

    private var glow: Color {
        if isDropTarget { return Theme.blue.opacity(0.6) }
        if isSelected { return Theme.blue.opacity(0.4) }
        return .clear
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
                                       description: Text("On the map, select a node, then hold it over another to file it there."))
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
    @Environment(ItemStore.self) private var store
    let item: Item
    let count: Int
    let open: () -> Void

    var body: some View {
        let kids = store.children(of: item.id)
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.blue)
                .frame(width: 26, height: 26)
                .overlay {
                    if !kids.isEmpty {
                        ProgressRing(fraction: Double(kids.filter { $0.status == .done }.count) / Double(kids.count),
                                     lineWidth: 2)
                    }
                }
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
        .nogFeedback(.selection, trigger: selected)
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
