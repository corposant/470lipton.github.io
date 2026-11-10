import CoreGraphics
import Foundation

/// Mind-map geometry, kept free of UI so it can be unit-tested.
enum MapLayout {
    struct Edge: Hashable {
        enum Kind: Hashable { case parent, link }
        let from: UUID
        let to: UUID
        let kind: Kind
    }

    /// Parent → child edges, plus [[link]] edges between visible items.
    static func edges(for items: [Item]) -> [Edge] {
        let ids = Set(items.map(\.id))
        var byTitle: [String: UUID] = [:]
        for item in items.sorted(by: { $0.created < $1.created }) where byTitle[item.title.lowercased()] == nil {
            byTitle[item.title.lowercased()] = item.id
        }
        var result: [Edge] = []
        var seen = Set<Edge>()
        for item in items {
            if let parent = item.parentID, ids.contains(parent) {
                let edge = Edge(from: parent, to: item.id, kind: .parent)
                if seen.insert(edge).inserted { result.append(edge) }
            }
            for title in item.outgoingLinkTitles {
                guard let target = byTitle[title.lowercased()], target != item.id else { continue }
                let edge = Edge(from: item.id, to: target, kind: .link)
                if seen.insert(edge).inserted { result.append(edge) }
            }
        }
        return result
    }

    /// Positions for every id. `pinned` positions are kept exactly; the rest are
    /// placed near their neighbours and relaxed with a simple force layout.
    /// Deterministic: the same input always gives the same picture.
    static func layout(ids: [UUID], edges: [Edge], pinned: [UUID: CGPoint],
                       spacing: CGFloat = 170, iterations: Int = 250) -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [:]
        for id in ids { if let p = pinned[id] { positions[id] = p } }

        var neighbours: [UUID: [UUID]] = [:]
        for e in edges {
            neighbours[e.from, default: []].append(e.to)
            neighbours[e.to, default: []].append(e.from)
        }

        // Initial placement: near an already-placed neighbour, else on a spiral.
        let free = ids.filter { positions[$0] == nil }
        var spiralIndex = 0
        for id in free {
            let angle = Double(seed(id) % 360) * .pi / 180
            if let anchor = neighbours[id]?.compactMap({ positions[$0] }).first {
                positions[id] = CGPoint(x: anchor.x + spacing * cos(angle), y: anchor.y + spacing * sin(angle))
            } else {
                let r = spacing * 0.9 * sqrt(Double(spiralIndex + pinned.count))
                let a = Double(spiralIndex) * 2.399963 // golden angle
                positions[id] = CGPoint(x: r * cos(a), y: r * sin(a))
                spiralIndex += 1
            }
        }
        guard !free.isEmpty, iterations > 0 else { return positions }

        // Relax only the free nodes. Arrays rather than dictionaries, and repulsion only
        // from nodes within a few spacings (found through a grid), so a page with
        // hundreds of items takes a moment instead of minutes. Far-off nodes barely
        // push anyway, and the pull toward the centre keeps everything together.
        let order = ids.filter { positions[$0] != nil }
        var index: [UUID: Int] = [:]
        for (i, id) in order.enumerated() { index[id] = i }
        var pts = order.map { positions[$0] ?? .zero }
        let isFree = order.map { pinned[$0] == nil }
        let links: [[Int]] = order.map { id in (neighbours[id] ?? []).compactMap { index[$0] } }
        let jitter = order.map { Double(seed($0) % 7 + 1) * 0.01 }
        let k = Double(spacing)
        let reach = k * 3.5
        // Fewer rounds on a big page: each one is more work, and it settles anyway.
        let rounds = order.count > 150 ? min(iterations, 120) : iterations
        var temperature = k
        var force = [CGVector](repeating: .zero, count: pts.count)
        for _ in 0..<rounds {
            var grid: [GridKey: [Int]] = [:]
            for i in pts.indices { grid[GridKey(pts[i], cell: CGSize(width: reach, height: reach)), default: []].append(i) }
            for a in pts.indices where isFree[a] {
                let pa = pts[a]
                var fx = 0.0, fy = 0.0
                let home = GridKey(pa, cell: CGSize(width: reach, height: reach))
                for gx in (home.x - 1)...(home.x + 1) {
                    for gy in (home.y - 1)...(home.y + 1) {
                        for b in grid[GridKey(x: gx, y: gy)] ?? [] where b != a {
                            let pb = pts[b]
                            var dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
                            var d = (dx * dx + dy * dy).squareRoot()
                            guard d < reach else { continue }
                            if d < 0.01 { dx = jitter[a]; dy = 0.01; d = 0.02 }
                            let repulse = k * k / d
                            fx += dx / d * repulse
                            fy += dy / d * repulse
                        }
                    }
                }
                for b in links[a] {
                    let pb = pts[b]
                    let dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
                    let d = max(0.01, (dx * dx + dy * dy).squareRoot())
                    let attract = d * d / k
                    fx -= dx / d * attract
                    fy -= dy / d * attract
                }
                // Gentle pull toward the centre keeps islands from drifting away.
                fx -= Double(pa.x) * 0.02
                fy -= Double(pa.y) * 0.02
                force[a] = CGVector(dx: fx, dy: fy)
            }
            for i in pts.indices where isFree[i] {
                let f = force[i]
                let magnitude = max(0.01, (f.dx * f.dx + f.dy * f.dy).squareRoot())
                let step = min(magnitude, temperature)
                pts[i] = CGPoint(x: pts[i].x + f.dx / magnitude * step, y: pts[i].y + f.dy / magnitude * step)
            }
            temperature = max(1, temperature * 0.97)
        }
        for (i, id) in order.enumerated() { positions[id] = pts[i] }
        return positions
    }

    /// A square of the grid used to find nearby chips quickly.
    struct GridKey: Hashable {
        let x: Int
        let y: Int

        init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }

        init(_ p: CGPoint, cell: CGSize) {
            // A stray infinite or NaN position mustn't crash the conversion to Int.
            func bucket(_ v: CGFloat, _ size: CGFloat) -> Int {
                let b = (v / size).rounded(.down)
                return b.isFinite ? Int(max(-1_000_000, min(1_000_000, b))) : 0
            }
            x = bucket(p.x, cell.width)
            y = bucket(p.y, cell.height)
        }
    }

    private static func seed(_ id: UUID) -> Int {
        Int(id.uuid.0) << 8 | Int(id.uuid.1)
    }
}

/// Stable colours for tags (zones on the map, dots in the outline).
enum TagPalette {
    static let colors: [(light: UInt32, dark: UInt32)] = [
        (0xA8265C, 0xFF74C8), // pink
        (0x6440BE, 0xBC9BFF), // violet
        (0x1D5CA3, 0x62C9FF), // blue
        (0x086C77, 0x4FE0E0), // cyan
        (0x8F5500, 0xFFB65C), // amber
        (0x137046, 0x6FE3A8), // mint
    ]

    static func color(for tag: String) -> (light: UInt32, dark: UInt32) {
        let hash = UInt32(NogPlanner.stableHash(tag.lowercased()), radix: 16) ?? 0
        return colors[Int(hash % UInt32(colors.count))]
    }
}

/// Map pages: "All", plus one page per #tag.
///
/// Tags flow down: a sub-item counts as having its parents' tags (worked out here,
/// nothing is rewritten). And a tag page always includes the parents of what it
/// shows, so the centre of a star never goes missing.
enum MapPage {
    /// An item's own tags plus every ancestor's, lowercased.
    static func effectiveTags(_ item: Item, in byID: [UUID: Item]) -> Set<String> {
        var tags = Set(item.tags.map { $0.lowercased() })
        var current = item.parentID
        var seen: Set<UUID> = [item.id]
        while let id = current, seen.insert(id).inserted, let parent = byID[id] {
            tags.formUnion(parent.tags.map { $0.lowercased() })
            current = parent.parentID
        }
        return tags
    }

    /// The items on a page: everything (page "") or everything carrying the tag
    /// (directly or inherited), plus the parents above them.
    static func items(_ all: [Item], page: String, showNogged: Bool) -> [Item] {
        let visible = all.filter { showNogged || $0.status != .done }
        guard !page.isEmpty else { return visible }
        let key = page.lowercased()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let visibleIDs = Set(visible.map(\.id))

        var included = Set<UUID>()
        for item in visible where effectiveTags(item, in: byID).contains(key) {
            included.insert(item.id)
            // Bring the parents along so the star keeps its centre.
            var current = item.parentID
            while let id = current, visibleIDs.contains(id), included.insert(id).inserted {
                current = byID[id]?.parentID
            }
        }
        return visible.filter { included.contains($0.id) }
    }

    /// Tags that have a page, busiest first (counting inherited tags).
    static func tags(_ all: [Item], showNogged: Bool) -> [(tag: String, count: Int)] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var counts: [String: Int] = [:]
        for item in all where showNogged || item.status != .done {
            for tag in effectiveTags(item, in: byID) { counts[tag, default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}

// MARK: - Smart arrangement

extension MapLayout {
    /// Room a standard chip needs, used until a chip has been measured.
    static let cell = CGSize(width: 196, height: 58)
    /// Clear space kept between chips, so titles never touch.
    static let spacing = CGSize(width: 28, height: 22)
    /// Distance from one standard chip's centre to the next on a shelf.
    static let pitch = CGSize(width: cell.width + spacing.width, height: cell.height + spacing.height)

    /// A chip's size: as measured on screen when we have it (long titles, large text),
    /// otherwise the standard cell.
    static func size(_ id: UUID, in sizes: [UUID: CGSize]) -> CGSize {
        guard let s = sizes[id], s.width > 1, s.height > 1 else { return cell }
        return CGSize(width: max(s.width, 40), height: max(s.height, 24))
    }

    /// A deliberate, tidy arrangement:
    /// - each project is a star: sub-items in a ring around it, their own sub-items fanned outward;
    /// - loose items sit on a two-column shelf, with notes that [[link]] to each other side by side;
    /// - things with the same tags are gathered into one group; groups sharing a tag sit next to each other;
    /// - a final pass nudges apart anything still overlapping, using each chip's real size.
    /// Deterministic: the same items always give the same picture. Centred on (0, 0).
    static func arrange(_ items: [Item], sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        let ids = Set(items.map(\.id))
        var children: [UUID: [Item]] = [:]
        for item in items {
            if let parent = item.parentID, parent != item.id, ids.contains(parent) {
                children[parent, default: []].append(item)
            }
        }
        for key in children.keys { children[key]?.sort { $0.created < $1.created } }

        // Who links to whom (either direction), to keep linked notes together.
        var linked: [UUID: Set<UUID>] = [:]
        for edge in edges(for: items) where edge.kind == .link {
            linked[edge.from, default: []].insert(edge.to)
            linked[edge.to, default: []].insert(edge.from)
        }

        func size(_ id: UUID) -> CGSize { MapLayout.size(id, in: sizes) }

        var visited = Set<UUID>()
        var weights: [UUID: Int] = [:]
        func weight(_ id: UUID, depth: Int = 0) -> Int {
            if let w = weights[id] { return w }
            guard depth < 12 else { return 1 }
            let w = max(1, (children[id] ?? []).reduce(0) { $0 + weight($1.id, depth: depth + 1) })
            weights[id] = w
            return w
        }

        /// Places a star around `id`; positions are relative to the star's centre.
        func star(_ id: UUID) -> [UUID: CGPoint] {
            var out: [UUID: CGPoint] = [:]
            func place(_ id: UUID, at p: CGPoint, angle: Double, spread: Double, depth: Int) {
                out[id] = p
                visited.insert(id)
                let kids = (children[id] ?? []).filter { !visited.contains($0.id) }
                guard !kids.isEmpty, depth < 8 else { return }
                let total = Double(kids.reduce(0) { $0 + weight($1.id) })
                // Radius big enough that the kids' chips fit along the arc.
                let arc = kids.reduce(0.0) { $0 + Double(size($1.id).width) + 14 }
                let radius = max(depth == 0 ? 210 : 180, arc / max(spread, 0.7))
                var a = angle - spread / 2
                for kid in kids {
                    let share = spread * Double(weight(kid.id)) / total
                    let mid = a + share / 2
                    let kp = CGPoint(x: p.x + cos(mid) * radius, y: p.y + sin(mid) * radius * 0.82)
                    place(kid.id, at: kp, angle: mid, spread: min(max(share, 0.9), .pi * 0.85), depth: depth + 1)
                    a += share
                }
            }
            place(id, at: .zero, angle: -.pi / 2, spread: 2 * .pi, depth: 0)
            return out
        }

        struct Block { var positions: [UUID: CGPoint]; var bounds: CGRect }
        func block(_ positions: [UUID: CGPoint]) -> Block {
            var rect = CGRect.null
            for (id, p) in positions {
                let s = size(id)
                rect = rect.union(CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height))
            }
            return Block(positions: positions, bounds: rect.isNull ? .zero : rect)
        }

        /// Shelf-packs blocks into rows no wider than `maxWidth`; returns one combined block.
        func pack(_ blocks: [Block], maxWidth: CGFloat, gap: CGFloat) -> Block {
            var out: [UUID: CGPoint] = [:]
            var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
            for b in blocks {
                if x > 0 && x + b.bounds.width > maxWidth {
                    x = 0; y += rowHeight + gap; rowHeight = 0
                }
                let dx = x - b.bounds.minX, dy = y - b.bounds.minY
                for (id, p) in b.positions { out[id] = CGPoint(x: p.x + dx, y: p.y + dy) }
                x += b.bounds.width + gap
                rowHeight = max(rowHeight, b.bounds.height)
            }
            return block(out)
        }

        /// A grid about as wide as it is tall (see `blockColumns`), rows as tall as their
        /// tallest chip, centres spaced so nothing touches. Never a long thin column.
        func shelf(_ items: [Item]) -> [UUID: CGPoint] {
            let column = (items.map { size($0.id).width }.max() ?? cell.width) + spacing.width
            let columns = max(2, blockColumns(items.count))
            var out: [UUID: CGPoint] = [:]
            var y: CGFloat = 0
            var previousHeight: CGFloat?
            for start in stride(from: 0, to: items.count, by: columns) {
                let row = items[start..<min(start + columns, items.count)]
                let height = row.map { size($0.id).height }.max() ?? cell.height
                if let previousHeight { y += previousHeight / 2 + spacing.height + height / 2 }
                for (i, item) in row.enumerated() {
                    out[item.id] = CGPoint(x: CGFloat(i) * column, y: y)
                }
                previousHeight = height
            }
            return out
        }

        /// Loose items in order, but each followed by the notes it links with (and theirs).
        func linkOrder(_ loose: [Item]) -> [Item] {
            let byID = Dictionary(loose.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<UUID>()
            var out: [Item] = []
            for item in loose where !seen.contains(item.id) {
                var queue = [item]
                seen.insert(item.id)
                while !queue.isEmpty {
                    let next = queue.removeFirst()
                    out.append(next)
                    let neighbours = (linked[next.id] ?? []).compactMap { byID[$0] }
                        .filter { !seen.contains($0.id) }
                        .sorted { $0.created < $1.created }
                    for n in neighbours { seen.insert(n.id); queue.append(n) }
                }
            }
            return out
        }

        // Roots: items whose parent isn't on this page. Anything stuck in a parent loop
        // is picked up afterwards as its own root.
        var roots = items.filter { $0.parentID.map { !ids.contains($0) } ?? true }
            .sorted { $0.created < $1.created }

        // Group roots by their whole set of tags ("admin", "admin+travel", "travel"), so
        // sorted groups that share a tag land next to each other. Untagged last.
        func groupKey(_ item: Item) -> String {
            let tags = Set(item.tags.map { $0.lowercased() }).sorted()
            return tags.isEmpty ? "\u{FFFF}" : tags.joined(separator: "+")
        }

        var groups: [String: [Item]] = [:]
        for root in roots { groups[groupKey(root), default: []].append(root) }
        var groupBlocks: [Block] = []
        for key in groups.keys.sorted() {
            var blocks: [Block] = []
            var loose: [Item] = []
            for root in groups[key] ?? [] where !visited.contains(root.id) {
                if (children[root.id] ?? []).isEmpty {
                    loose.append(root)
                    visited.insert(root.id)
                } else {
                    blocks.append(block(star(root.id)))
                }
            }
            if !loose.isEmpty { blocks.append(block(shelf(linkOrder(loose)))) }
            if !blocks.isEmpty {
                let width = rowWidth(blocks.map(\.positions), sizes: sizes, least: 1100)
                groupBlocks.append(pack(blocks, maxWidth: width, gap: 90))
            }
        }
        // Anything not yet placed (e.g. caught in a parent loop) goes on a final shelf.
        roots = items.filter { !visited.contains($0.id) }
        if !roots.isEmpty { groupBlocks.append(block(shelf(roots))) }

        // Groups sit far enough apart that their tag zones (and the labels on top) never touch.
        var all = pack(groupBlocks, maxWidth: rowWidth(groupBlocks.map(\.positions), sizes: sizes, least: 1700), gap: 160)
        // Centre on (0, 0).
        let cx = all.bounds.midX, cy = all.bounds.midY
        for (id, p) in all.positions { all.positions[id] = CGPoint(x: p.x - cx, y: p.y - cy) }
        return separate(all.positions, sizes: sizes)
    }

    /// Nudges apart any chips that overlap or crowd each other, using each chip's size
    /// and keeping `gap` clear between them. Chips in `fixed` never move: the other one
    /// of a pair takes the whole push. Deterministic.
    static func separate(_ positions: [UUID: CGPoint], sizes: [UUID: CGSize] = [:], fixed: Set<UUID> = [],
                         gap: CGSize = spacing, iterations: Int = 150) -> [UUID: CGPoint] {
        let keys = positions.keys.sorted { $0.uuidString < $1.uuidString }
        guard keys.count > 1 else { return positions }
        var p = keys.map { positions[$0] ?? .zero }
        let dims = keys.map { MapLayout.size($0, in: sizes) }
        let isFixed = keys.map { fixed.contains($0) }
        // Two chips can only crowd each other when their centres are closer than the
        // widest (and tallest) chip plus the gap, so with grid squares that size, each
        // chip only needs checking against the squares around its own. That keeps a
        // page of hundreds of chips quick instead of comparing every pair.
        let square = CGSize(width: (dims.map(\.width).max() ?? cell.width) + gap.width,
                            height: (dims.map(\.height).max() ?? cell.height) + gap.height)
        for _ in 0..<iterations {
            var grid: [GridKey: [Int]] = [:]
            let homes = p.map { GridKey($0, cell: square) }
            for i in p.indices { grid[homes[i], default: []].append(i) }
            var moved = false
            for i in p.indices {
                var near: [Int] = []
                for gx in (homes[i].x - 1)...(homes[i].x + 1) {
                    for gy in (homes[i].y - 1)...(homes[i].y + 1) {
                        for j in grid[GridKey(x: gx, y: gy)] ?? [] where j > i { near.append(j) }
                    }
                }
                near.sort()
                for j in near {
                    let fa = isFixed[i], fb = isFixed[j]
                    if fa && fb { continue }
                    let a = p[i], b = p[j], sa = dims[i], sb = dims[j]
                    let ox = (sa.width + sb.width) / 2 + gap.width - abs(a.x - b.x)
                    let oy = (sa.height + sb.height) / 2 + gap.height - abs(a.y - b.y)
                    guard ox > 0.01, oy > 0.01 else { continue }
                    moved = true
                    // Each takes half the push, or the movable one takes all of it.
                    let shareA: CGFloat = fa ? 0 : (fb ? 1 : 0.5)
                    let shareB: CGFloat = 1 - shareA
                    if ox < oy {
                        let dir: CGFloat = a.x <= b.x ? -1 : 1
                        p[i] = CGPoint(x: a.x + dir * ox * shareA, y: a.y)
                        p[j] = CGPoint(x: b.x - dir * ox * shareB, y: b.y)
                    } else {
                        let dir: CGFloat = a.y <= b.y ? -1 : 1
                        p[i] = CGPoint(x: a.x, y: a.y + dir * oy * shareA)
                        p[j] = CGPoint(x: b.x, y: b.y - dir * oy * shareB)
                    }
                }
            }
            if !moved { break }
        }
        var out: [UUID: CGPoint] = [:]
        for (i, id) in keys.enumerated() { out[id] = p[i] }
        return out
    }

    /// Places `missing` near what they're connected to, then pushes only them clear of
    /// everything else. The chips already in `pinned` stay exactly where they are.
    static func place(missing ids: [UUID], edges: [Edge], pinned: [UUID: CGPoint],
                      sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        let laidOut = layout(ids: Array(pinned.keys) + ids.filter { pinned[$0] == nil }, edges: edges, pinned: pinned)
        return separate(laidOut, sizes: sizes, fixed: Set(pinned.keys))
    }

    /// More new chips than this at once (an import, say) are laid out as their own tidy
    /// block beside the map, instead of being squeezed in one by one.
    static let bulkPlacement = 24

    /// Lays out many new items as one tidy block (see `arrange`) and puts it to the right
    /// of the chips already on the map, level with their middle. Returns spots for `items` only.
    static func placeBeside(_ items: [Item], existing: [UUID: CGPoint], sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        let block = arrange(items, sizes: sizes)
        func bounds(_ p: [UUID: CGPoint]) -> CGRect {
            var r = CGRect.null
            for (id, q) in p {
                let s = size(id, in: sizes)
                r = r.union(CGRect(x: q.x - s.width / 2, y: q.y - s.height / 2, width: s.width, height: s.height))
            }
            return r
        }
        let old = bounds(existing), new = bounds(block)
        guard !old.isNull, !new.isNull else { return block }
        // Far enough that the tag zones around each side don't touch.
        let dx = old.maxX + 260 - new.minX, dy = old.midY - new.midY
        return block.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// True if any two chips overlap (ignoring the gap).
    static func hasOverlap(_ positions: [UUID: CGPoint], sizes: [UUID: CGSize] = [:]) -> Bool {
        let keys = Array(positions.keys)
        for i in keys.indices {
            for j in keys.indices where j > i {
                guard let a = positions[keys[i]], let b = positions[keys[j]] else { continue }
                let sa = size(keys[i], in: sizes), sb = size(keys[j], in: sizes)
                if abs(a.x - b.x) < (sa.width + sb.width) / 2 - 0.5 && abs(a.y - b.y) < (sa.height + sb.height) / 2 - 0.5 {
                    return true
                }
            }
        }
        return false
    }
}
