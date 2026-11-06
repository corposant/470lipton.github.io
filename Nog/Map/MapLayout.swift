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

        // Relax only the free nodes.
        let freeSet = Set(free)
        let k = Double(spacing)
        var temperature = k
        for _ in 0..<iterations {
            var force: [UUID: CGVector] = [:]
            for a in free {
                guard let pa = positions[a] else { continue }
                var fx = 0.0, fy = 0.0
                for b in ids where b != a {
                    guard let pb = positions[b] else { continue }
                    var dx = pa.x - pb.x, dy = pa.y - pb.y
                    var d = sqrt(dx * dx + dy * dy)
                    if d < 0.01 { dx = 0.01 * Double(seed(a) % 7 + 1); dy = 0.01; d = 0.02 }
                    let repulse = k * k / d
                    fx += dx / d * repulse
                    fy += dy / d * repulse
                }
                for b in neighbours[a] ?? [] {
                    guard let pb = positions[b] else { continue }
                    let dx = pa.x - pb.x, dy = pa.y - pb.y
                    let d = max(0.01, sqrt(dx * dx + dy * dy))
                    let attract = d * d / k
                    fx -= dx / d * attract
                    fy -= dy / d * attract
                }
                // Gentle pull toward the centre keeps islands from drifting away.
                fx -= pa.x * 0.02
                fy -= pa.y * 0.02
                force[a] = CGVector(dx: fx, dy: fy)
            }
            for id in freeSet {
                guard let f = force[id], let p = positions[id] else { continue }
                let magnitude = max(0.01, sqrt(f.dx * f.dx + f.dy * f.dy))
                let step = min(magnitude, temperature)
                positions[id] = CGPoint(x: p.x + f.dx / magnitude * step, y: p.y + f.dy / magnitude * step)
            }
            temperature = max(1, temperature * 0.97)
        }
        return positions
    }

    private static func seed(_ id: UUID) -> Int {
        Int(id.uuid.0) << 8 | Int(id.uuid.1)
    }
}

/// Stable colours for tags (zones on the map, dots in the outline).
enum TagPalette {
    static let colors: [(light: UInt32, dark: UInt32)] = [
        (0xD93A86, 0xFF5FB0), // pink
        (0x7656DB, 0xA17BFF), // violet
        (0x1C7ED6, 0x4FB3FF), // blue
        (0x0E9AA7, 0x4FE0E0), // cyan
        (0xC77800, 0xFFB65C), // amber
        (0x1E9E62, 0x6FE3A8), // mint
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
    /// Room each node needs (a chip plus breathing space).
    static let cell = CGSize(width: 196, height: 58)

    /// A deliberate, tidy arrangement:
    /// - each project is a star: sub-items in a ring around it, their own sub-items fanned outward;
    /// - loose items sit on a two-column shelf;
    /// - things sharing a tag are gathered into one group, groups packed in rows;
    /// - a final pass nudges apart anything still overlapping.
    /// Deterministic: the same items always give the same picture. Centred on (0, 0).
    static func arrange(_ items: [Item]) -> [UUID: CGPoint] {
        let ids = Set(items.map(\.id))
        var children: [UUID: [Item]] = [:]
        for item in items {
            if let parent = item.parentID, parent != item.id, ids.contains(parent) {
                children[parent, default: []].append(item)
            }
        }
        for key in children.keys { children[key]?.sort { $0.created < $1.created } }

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
                let radius = max(depth == 0 ? 170 : 140, Double(kids.count) * 170 / max(spread, 0.7))
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

        // Roots: items whose parent isn't on this page. Anything stuck in a parent loop
        // is picked up afterwards as its own root.
        var roots = items.filter { $0.parentID.map { !ids.contains($0) } ?? true }
            .sorted { $0.created < $1.created }

        // Group roots by tag (first tag alphabetically), untagged last.
        func groupKey(_ item: Item) -> String {
            item.tags.map { $0.lowercased() }.sorted().first ?? "\u{FFFF}"
        }

        struct Block { var positions: [UUID: CGPoint]; var bounds: CGRect }
        func block(_ positions: [UUID: CGPoint]) -> Block {
            let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
            let rect = CGRect(x: (xs.min() ?? 0) - cell.width / 2, y: (ys.min() ?? 0) - cell.height / 2,
                              width: (xs.max() ?? 0) - (xs.min() ?? 0) + cell.width,
                              height: (ys.max() ?? 0) - (ys.min() ?? 0) + cell.height)
            return Block(positions: positions, bounds: rect)
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
            if !loose.isEmpty {
                var shelf: [UUID: CGPoint] = [:]
                for (i, item) in loose.enumerated() {
                    shelf[item.id] = CGPoint(x: CGFloat(i % 2) * cell.width, y: CGFloat(i / 2) * cell.height)
                }
                blocks.append(block(shelf))
            }
            if !blocks.isEmpty { groupBlocks.append(pack(blocks, maxWidth: 1000, gap: 60)) }
        }
        // Anything not yet placed (e.g. caught in a parent loop) goes on a final shelf.
        roots = items.filter { !visited.contains($0.id) }
        if !roots.isEmpty {
            var shelf: [UUID: CGPoint] = [:]
            for (i, item) in roots.enumerated() {
                shelf[item.id] = CGPoint(x: CGFloat(i % 2) * cell.width, y: CGFloat(i / 2) * cell.height)
            }
            groupBlocks.append(block(shelf))
        }

        var all = pack(groupBlocks, maxWidth: 1500, gap: 140)
        // Centre on (0, 0).
        let cx = all.bounds.midX, cy = all.bounds.midY
        for (id, p) in all.positions { all.positions[id] = CGPoint(x: p.x - cx, y: p.y - cy) }
        return separate(all.positions)
    }

    /// Nudges apart any nodes whose chips overlap.
    static func separate(_ positions: [UUID: CGPoint], iterations: Int = 150) -> [UUID: CGPoint] {
        var p = positions
        let keys = p.keys.sorted { $0.uuidString < $1.uuidString }
        let w = cell.width - 6, h = cell.height - 8
        for _ in 0..<iterations {
            var moved = false
            for i in keys.indices {
                for j in keys.indices where j > i {
                    guard let a = p[keys[i]], let b = p[keys[j]] else { continue }
                    let ox = w - abs(a.x - b.x), oy = h - abs(a.y - b.y)
                    guard ox > 0, oy > 0 else { continue }
                    moved = true
                    if ox < oy {
                        let push = ox / 2 * (a.x <= b.x ? -1 : 1)
                        p[keys[i]] = CGPoint(x: a.x + push, y: a.y)
                        p[keys[j]] = CGPoint(x: b.x - push, y: b.y)
                    } else {
                        let push = oy / 2 * (a.y <= b.y ? -1 : 1)
                        p[keys[i]] = CGPoint(x: a.x, y: a.y + push)
                        p[keys[j]] = CGPoint(x: b.x, y: b.y - push)
                    }
                }
            }
            if !moved { break }
        }
        return p
    }
}
