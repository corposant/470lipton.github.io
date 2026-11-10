import CoreGraphics
import Foundation

/// The wand: a gentle tidy-up that keeps your arrangement, and whole-page layouts.
/// All pure and deterministic (same items, same picture), so they run off the main
/// thread and can be unit-tested.
extension MapLayout {
    /// Whole-page layouts in the wand's menu.
    enum Style: String, CaseIterable, Identifiable {
        case stars, mindMap, byTag, web, grid

        var id: String { rawValue }

        /// The layouts in the wand's menu. Grid has its own button.
        static let wand: [Style] = [.stars, .mindMap, .byTag, .web]

        var title: String {
            switch self {
            case .stars: "Stars"
            case .mindMap: "Mind map"
            case .byTag: "By tag"
            case .web: "Web"
            case .grid: "Grid"
            }
        }

        var icon: String {
            switch self {
            case .stars: "sun.max"
            case .mindMap: "point.3.connected.trianglepath.dotted"
            case .byTag: "tag"
            case .web: "circle.hexagongrid"
            case .grid: "square.grid.3x3"
            }
        }

        /// One line for the menu and VoiceOver.
        var detail: String {
            switch self {
            case .stars: "Each project in a ring of its sub-nogs"
            case .mindMap: "Branches out to the left and right"
            case .byTag: "Tidy blocks, one per set of tags"
            case .web: "Linked notes pulled close together"
            case .grid: "Everything in even rows and columns"
            }
        }
    }

    /// Lays out every item on the page in `style`. Centred on (0, 0).
    static func layOut(_ style: Style, items: [Item], sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        switch style {
        case .stars: squeeze(arrange(items, sizes: sizes), sizes: sizes)
        case .mindMap: squeeze(mindMap(items, sizes: sizes), sizes: sizes)
        case .byTag: squeeze(byTag(items, sizes: sizes), sizes: sizes)
        case .web: squeeze(web(items, sizes: sizes), sizes: sizes)
        case .grid: grid(items, sizes: sizes)
        }
    }

    // MARK: Tidy up

    /// Fixes the mess without rearranging: sub-items that wandered off come back near
    /// their folder, overlaps are pushed apart, and tag zones that don't share items are
    /// moved off each other. Pinned chips never move, and on a map that's already tidy
    /// nothing moves at all. Items without a position are left out.
    static func cleanup(_ items: [Item], positions: [UUID: CGPoint], pinned: Set<UUID>,
                        sizes: [UUID: CGSize] = [:], zones: [Set<UUID>] = []) -> [UUID: CGPoint] {
        // One pass can leave work for the next (a sub-nog pulled back next to its folder
        // gets pushed out again by a neighbour, say), so repeat until nothing changes.
        // Then tidying a tidied map moves nothing.
        var p = tidyPass(items, positions: positions, pinned: pinned, sizes: sizes, zones: zones)
        for _ in 0..<6 {
            let next = tidyPass(items, positions: p, pinned: pinned, sizes: sizes, zones: zones)
            if next == p { break }
            p = next
        }
        return p
    }

    private static func tidyPass(_ items: [Item], positions: [UUID: CGPoint], pinned: Set<UUID>,
                                 sizes: [UUID: CGSize], zones: [Set<UUID>]) -> [UUID: CGPoint] {
        let ids = Set(items.map(\.id))
        var p = positions.filter { ids.contains($0.key) }
        let fixed = pinned.intersection(p.keys)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Sub-items that wandered off come back within reach of their folder, keeping
        //    their direction. Parents first, so a pulled folder brings its own along.
        func depth(_ item: Item) -> Int {
            var d = 0
            var current = item.parentID
            var seen: Set<UUID> = [item.id]
            while let id = current, let parent = byID[id], seen.insert(id).inserted {
                d += 1
                current = parent.parentID
            }
            return d
        }
        let reach = pitch.width * 2.2
        let ordered = items.sorted { (depth($0), $0.created) < (depth($1), $1.created) }
        for item in ordered {
            guard !fixed.contains(item.id), let parent = item.parentID, parent != item.id,
                  let c = p[item.id], let f = p[parent] else { continue }
            let dx = c.x - f.x, dy = c.y - f.y
            let d = (dx * dx + dy * dy).squareRoot()
            guard d > reach else { continue }
            let k = pitch.width * 1.2 / d
            p[item.id] = CGPoint(x: f.x + dx * k, y: f.y + dy * k)
        }

        // 2. No overlaps, then zones apart, then overlaps again (moving a zone can cause some).
        p = separate(p, sizes: sizes, fixed: fixed)
        p = separateZones(p, zones: zones, sizes: sizes, fixed: fixed)
        p = separate(p, sizes: sizes, fixed: fixed)
        // 3. Close up any wide empty stretches, so the map never sprawls.
        return squeeze(p, sizes: sizes, fixed: fixed)
    }

    /// The most empty space allowed between neighbouring chips across the map: room for
    /// two tag zone borders and a zone title, and not much more.
    static let maxGap: CGFloat = 160

    /// Closes up empty stretches wider than `maxGap`, across and down. Everything on one
    /// side of an empty stretch slides over as a whole, so nothing ends up overlapping
    /// and the arrangement on each side stays exactly as it was. The side without pinned
    /// chips is the one that moves; a stretch with pinned chips on both sides stays.
    static func squeeze(_ positions: [UUID: CGPoint], sizes: [UUID: CGSize] = [:], fixed: Set<UUID> = [],
                        maxGap: CGFloat = MapLayout.maxGap) -> [UUID: CGPoint] {
        var p = positions
        guard p.count > 1 else { return p }
        for across in [true, false] {
            // Each round closes one stretch, so this ends; the cap is only a safety net.
            for _ in 0..<p.count {
                let spans = p.map { entry -> (id: UUID, lo: CGFloat, hi: CGFloat) in
                    let s = size(entry.key, in: sizes)
                    let c = across ? entry.value.x : entry.value.y
                    let half = (across ? s.width : s.height) / 2
                    return (entry.key, c - half, c + half)
                }
                .sorted { ($0.lo, $0.id.uuidString) < ($1.lo, $1.id.uuidString) }
                var reach = spans[0].hi
                var move: (ids: [UUID], by: CGFloat)?
                for i in spans.indices.dropFirst() {
                    let gap = spans[i].lo - reach
                    if gap > maxGap {
                        let before = spans[..<i].map(\.id), after = spans[i...].map(\.id)
                        let close = gap - maxGap
                        if !after.contains(where: { fixed.contains($0) }) {
                            move = (after, -close)
                        } else if !before.contains(where: { fixed.contains($0) }) {
                            move = (before, close)
                        }
                        if move != nil { break }
                    }
                    reach = max(reach, spans[i].hi)
                }
                guard let move else { break }
                for id in move.ids {
                    guard let q = p[id] else { continue }
                    p[id] = across ? CGPoint(x: q.x + move.by, y: q.y) : CGPoint(x: q.x, y: q.y + move.by)
                }
            }
        }
        return p
    }

    /// Moves tag zones that share no items off each other, the smaller zone moving.
    /// Zones that share items (or nest) can't be pulled apart, so they're left alone.
    static func separateZones(_ positions: [UUID: CGPoint], zones: [Set<UUID>], sizes: [UUID: CGSize] = [:],
                              fixed: Set<UUID> = [], iterations: Int = 40) -> [UUID: CGPoint] {
        var p = positions
        // Zone borders sit about this far outside their chips (see MindMapView.zoneInset).
        let pad = CGSize(width: 36, height: 44)
        func rect(_ members: Set<UUID>) -> CGRect? {
            var r = CGRect.null
            for id in members {
                guard let q = p[id] else { continue }
                let s = size(id, in: sizes)
                r = r.union(CGRect(x: q.x - s.width / 2, y: q.y - s.height / 2, width: s.width, height: s.height))
            }
            return r.isNull ? nil : r.insetBy(dx: -pad.width, dy: -pad.height)
        }
        // A zone whose chips are scattered all over the map (sub-nogs whose tags differ
        // from their folder's, say) wraps a huge box that overlaps everything. Shoving it
        // would fling chips far away and still not separate anything, so it stays put.
        func isCompact(_ members: Set<UUID>) -> Bool {
            guard let r = rect(members) else { return false }
            let chips = members.reduce(CGFloat(0)) { sum, id in
                let s = size(id, in: sizes)
                return sum + (s.width + spacing.width) * (s.height + spacing.height)
            }
            return r.width * r.height <= chips * 4 + pad.width * pad.height * 8
        }
        let sorted = zones.filter { !$0.isEmpty && isCompact($0) }
            .sorted { ($0.count, $0.map(\.uuidString).min() ?? "") < ($1.count, $1.map(\.uuidString).min() ?? "") }
        // How far one zone may travel in all: tidying nudges, it doesn't relocate.
        let maxTravel = pitch.width * 3
        var travelled = [CGFloat](repeating: 0, count: sorted.count)
        for _ in 0..<iterations {
            var moved = false
            for i in sorted.indices {
                for j in sorted.indices where j > i {
                    let small = sorted[i], big = sorted[j]
                    guard small.isDisjoint(with: big),
                          let rs = rect(small), let rb = rect(big) else { continue }
                    let overlap = rs.intersection(rb)
                    guard !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 else { continue }
                    let movable = small.subtracting(fixed).filter { p[$0] != nil }
                    guard !movable.isEmpty else { continue }
                    var shift = CGVector.zero
                    if overlap.width < overlap.height {
                        shift.dx = (rs.midX <= rb.midX ? -1 : 1) * (overlap.width + 1)
                    } else {
                        shift.dy = (rs.midY <= rb.midY ? -1 : 1) * (overlap.height + 1)
                    }
                    let distance = abs(shift.dx) + abs(shift.dy)
                    guard travelled[i] + distance <= maxTravel else { continue }
                    travelled[i] += distance
                    for id in movable {
                        if let q = p[id] { p[id] = CGPoint(x: q.x + shift.dx, y: q.y + shift.dy) }
                    }
                    moved = true
                }
            }
            if !moved { break }
        }
        return p
    }

    // MARK: Mind map

    /// A classic mind map: with one project, it sits in the middle and its branches
    /// spread left and right; with several, the projects themselves split left and right.
    /// Each branch is a tidy tree: leaves stacked, every folder centred on its sub-items.
    static func mindMap(_ items: [Item], sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        guard !items.isEmpty else { return [:] }
        let ids = Set(items.map(\.id))
        var children: [UUID: [Item]] = [:]
        for item in items {
            if let parent = item.parentID, parent != item.id, ids.contains(parent) {
                children[parent, default: []].append(item)
            }
        }
        for key in children.keys { children[key]?.sort { $0.created < $1.created } }
        var roots = items.filter { $0.parentID.map { !ids.contains($0) } ?? true }
            .sorted { $0.created < $1.created }
        if roots.isEmpty, let first = items.min(by: { $0.created < $1.created }) { roots = [first] } // all in a loop
        // With several roots, lone nogs (no folder, no sub-nogs) aren't branches of
        // anything: stacked down the sides they made one endless column. They go in a
        // compact grid underneath instead, and only real projects branch out.
        var loose: [Item] = []
        if roots.count > 1 {
            loose = roots.filter { (children[$0.id] ?? []).isEmpty }
            roots = roots.filter { !(children[$0.id] ?? []).isEmpty }
        }

        let rowGap = spacing.height, columnGap: CGFloat = 64
        func size(_ id: UUID) -> CGSize { MapLayout.size(id, in: sizes) }

        var leafCounts: [UUID: Int] = [:]
        func leaves(_ id: UUID, depth: Int = 0) -> Int {
            if let n = leafCounts[id] { return n }
            guard depth < 32 else { return 1 }
            let kids = children[id] ?? []
            let n = kids.isEmpty ? 1 : kids.reduce(0) { $0 + leaves($1.id, depth: depth + 1) }
            leafCounts[id] = n
            return n
        }

        var out: [UUID: CGPoint] = [:]
        var visited = Set<UUID>()

        /// Lays out one side; `cursor` is the next free y on that side.
        func place(_ id: UUID, x: CGFloat, direction: CGFloat, cursor: inout CGFloat) {
            visited.insert(id)
            let s = size(id)
            let kids = (children[id] ?? []).filter { !visited.contains($0.id) }
            guard !kids.isEmpty else {
                out[id] = CGPoint(x: x, y: cursor + s.height / 2)
                cursor += s.height + rowGap
                return
            }
            var placedKids: [UUID] = []
            for kid in kids where !visited.contains(kid.id) {
                let kx = x + direction * (s.width / 2 + columnGap + size(kid.id).width / 2)
                place(kid.id, x: kx, direction: direction, cursor: &cursor)
                placedKids.append(kid.id)
            }
            let ys = placedKids.compactMap { out[$0]?.y }
            let y = ys.isEmpty ? cursor + s.height / 2 : (ys.min()! + ys.max()!) / 2
            out[id] = CGPoint(x: x, y: y)
            cursor = max(cursor, y + s.height / 2 + rowGap)
        }

        /// Splits branches between the two sides so each has about the same number of leaves.
        func split(_ branches: [Item]) -> (right: [Item], left: [Item]) {
            let total = branches.reduce(0) { $0 + leaves($1.id) }
            var right: [Item] = [], left: [Item] = []
            var count = 0
            for branch in branches {
                if count * 2 < total { right.append(branch); count += leaves(branch.id) } else { left.append(branch) }
            }
            return (right, left)
        }

        /// Shifts a side so it's centred on y = 0.
        func centre(_ side: [UUID]) {
            let ys = side.compactMap { out[$0]?.y }
            guard let lo = ys.min(), let hi = ys.max() else { return }
            let mid = (lo + hi) / 2
            for id in side { if let q = out[id] { out[id] = CGPoint(x: q.x, y: q.y - mid) } }
        }

        func layOutSide(_ branches: [Item], startX: (Item) -> CGFloat, direction: CGFloat) {
            var cursor: CGFloat = 0
            let before = Set(out.keys)
            for branch in branches where !visited.contains(branch.id) {
                place(branch.id, x: startX(branch), direction: direction, cursor: &cursor)
            }
            centre(Array(Set(out.keys).subtracting(before)))
        }

        if roots.isEmpty {
            // Nothing but lone nogs: just the grid below.
        } else if roots.count == 1, let root = roots.first {
            // One project: it's the centre.
            visited.insert(root.id)
            out[root.id] = .zero
            let rw = size(root.id).width
            let sides = split(children[root.id] ?? [])
            layOutSide(sides.right, startX: { rw / 2 + columnGap + size($0.id).width / 2 }, direction: 1)
            layOutSide(sides.left, startX: { -(rw / 2 + columnGap + size($0.id).width / 2) }, direction: -1)
        } else {
            let sides = split(roots)
            layOutSide(sides.right, startX: { columnGap / 2 + size($0.id).width / 2 }, direction: 1)
            layOutSide(sides.left, startX: { -(columnGap / 2 + size($0.id).width / 2) }, direction: -1)
        }

        // The lone nogs, in a grid centred underneath.
        if !loose.isEmpty {
            let columns = blockColumns(loose.count)
            let column = (loose.map { size($0.id).width }.max() ?? cell.width) + spacing.width
            let bottom = out.map { $0.value.y + size($0.key).height / 2 }.max()
            var y = bottom.map { $0 + 120 } ?? 0
            var previous: CGFloat?
            for start in stride(from: 0, to: loose.count, by: columns) {
                let row = loose[start..<min(start + columns, loose.count)]
                let height = row.map { size($0.id).height }.max() ?? cell.height
                if let previous { y += previous / 2 + spacing.height + height / 2 } else { y += height / 2 }
                for (i, item) in row.enumerated() {
                    visited.insert(item.id)
                    out[item.id] = CGPoint(x: (CGFloat(i) - CGFloat(columns - 1) / 2) * column, y: y)
                }
                previous = height
            }
        }

        // Anything caught in a parent loop goes in a column underneath.
        var y = (out.values.map(\.y).max() ?? 0) + pitch.height * 1.5
        for item in items where out[item.id] == nil {
            out[item.id] = CGPoint(x: 0, y: y)
            y += size(item.id).height + rowGap
        }
        return separate(out, sizes: sizes)
    }

    // MARK: By tag

    /// One tidy block per set of tags (sub-items count as having their folder's tags),
    /// each block a small grid in outline order, blocks packed in rows.
    static func byTag(_ items: [Item], sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        guard !items.isEmpty else { return [:] }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func key(_ item: Item) -> String {
            let tags = MapPage.effectiveTags(item, in: byID).sorted()
            return tags.isEmpty ? "\u{FFFF}" : tags.joined(separator: "+")
        }
        var groups: [String: [Item]] = [:]
        for item in items { groups[key(item), default: []].append(item) }

        var blocks: [[UUID: CGPoint]] = []
        for k in groups.keys.sorted() {
            let members = outlineOrder(groups[k] ?? [])
            let columns = blockColumns(members.count)
            let width = (members.map { size($0.id, in: sizes).width }.max() ?? cell.width) + spacing.width
            var block: [UUID: CGPoint] = [:]
            var y: CGFloat = 0
            var previous: CGFloat?
            for start in stride(from: 0, to: members.count, by: columns) {
                let row = members[start..<min(start + columns, members.count)]
                let height = row.map { size($0.id, in: sizes).height }.max() ?? cell.height
                if let previous { y += previous / 2 + spacing.height + height / 2 }
                for (i, item) in row.enumerated() { block[item.id] = CGPoint(x: CGFloat(i) * width, y: y) }
                previous = height
            }
            blocks.append(block)
        }
        return separate(packBlocks(blocks, sizes: sizes, maxWidth: rowWidth(blocks, sizes: sizes, least: 1500), gap: 140),
                        sizes: sizes)
    }

    /// Folders followed by what's inside them, oldest first at each level.
    static func outlineOrder(_ items: [Item]) -> [Item] {
        let ids = Set(items.map(\.id))
        var children: [UUID: [Item]] = [:]
        for item in items {
            if let parent = item.parentID, parent != item.id, ids.contains(parent) {
                children[parent, default: []].append(item)
            }
        }
        var out: [Item] = []
        var seen = Set<UUID>()
        func visit(_ item: Item) {
            guard seen.insert(item.id).inserted else { return }
            out.append(item)
            for kid in (children[item.id] ?? []).sorted(by: { $0.created < $1.created }) { visit(kid) }
        }
        let roots = items.filter { $0.parentID.map { !ids.contains($0) } ?? true }.sorted { $0.created < $1.created }
        for root in roots { visit(root) }
        for item in items.sorted(by: { $0.created < $1.created }) { visit(item) } // loops
        return out
    }

    // MARK: Web

    /// A force layout: everything joined by a line (folder or [[link]]) pulls together,
    /// everything else pushes apart. Good for notes with lots of links.
    static func web(_ items: [Item], sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        guard !items.isEmpty else { return [:] }
        let ids = items.sorted { $0.created < $1.created }.map(\.id)
        let p = layout(ids: ids, edges: edges(for: items), pinned: [:], spacing: 250, iterations: 300)
        return separate(centred(p), sizes: sizes)
    }

    // MARK: Grid

    /// Every chip in one even grid, about as wide as it is tall: folders followed by
    /// their sub-nogs, oldest first. Every cell is the size of the biggest chip, so the
    /// rows and columns line up exactly.
    static func grid(_ items: [Item], sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        guard !items.isEmpty else { return [:] }
        let ordered = outlineOrder(items)
        let biggest = ordered.reduce(CGSize.zero) { s, item in
            let c = size(item.id, in: sizes)
            return CGSize(width: max(s.width, c.width), height: max(s.height, c.height))
        }
        let step = CGSize(width: biggest.width + spacing.width, height: biggest.height + spacing.height)
        // Columns so the grid comes out about square on screen.
        let columns = max(1, Int((Double(ordered.count) * Double(step.height / step.width)).squareRoot().rounded(.up)))
        var out: [UUID: CGPoint] = [:]
        for (i, item) in ordered.enumerated() {
            out[item.id] = CGPoint(x: CGFloat(i % columns) * step.width, y: CGFloat(i / columns) * step.height)
        }
        return centred(out)
    }

    // MARK: Helpers

    /// Columns for a block of `count` chips: about as wide as it is tall on screen
    /// (chips are wide and short), never a long thin column.
    static func blockColumns(_ count: Int) -> Int {
        max(1, min(8, Int((Double(count).squareRoot() * 0.85).rounded(.up))))
    }

    /// How wide a row of blocks may get before the next row starts: enough that the
    /// whole page comes out roughly square, rather than a tall tower of blocks.
    static func rowWidth(_ blocks: [[UUID: CGPoint]], sizes: [UUID: CGSize], least: CGFloat) -> CGFloat {
        let area = blocks.reduce(CGFloat(0)) { sum, block in
            sum + block.keys.reduce(CGFloat(0)) { s, id in
                let c = size(id, in: sizes)
                return s + (c.width + spacing.width) * (c.height + spacing.height)
            }
        }
        // Blocks don't tile perfectly, so allow for some slack between them.
        return max(least, (area * 1.8).squareRoot())
    }

    /// Shelf-packs blocks (each in its own coordinates) into rows, then centres the lot on (0, 0).
    static func packBlocks(_ blocks: [[UUID: CGPoint]], sizes: [UUID: CGSize], maxWidth: CGFloat, gap: CGFloat) -> [UUID: CGPoint] {
        func bounds(_ block: [UUID: CGPoint]) -> CGRect {
            var r = CGRect.null
            for (id, q) in block {
                let s = size(id, in: sizes)
                r = r.union(CGRect(x: q.x - s.width / 2, y: q.y - s.height / 2, width: s.width, height: s.height))
            }
            return r.isNull ? .zero : r
        }
        var out: [UUID: CGPoint] = [:]
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for block in blocks where !block.isEmpty {
            let b = bounds(block)
            if x > 0 && x + b.width > maxWidth {
                x = 0; y += rowHeight + gap; rowHeight = 0
            }
            for (id, q) in block { out[id] = CGPoint(x: q.x - b.minX + x, y: q.y - b.minY + y) }
            x += b.width + gap
            rowHeight = max(rowHeight, b.height)
        }
        return centred(out)
    }

    /// The same picture, moved so its middle is (0, 0).
    static func centred(_ p: [UUID: CGPoint]) -> [UUID: CGPoint] {
        let xs = p.values.map(\.x), ys = p.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return p }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        return p.mapValues { CGPoint(x: $0.x - cx, y: $0.y - cy) }
    }
}
