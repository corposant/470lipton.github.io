import CoreGraphics
import Foundation

/// The map's honeycomb: the cells every chip settles into.
///
/// Chips are wide and short, so the cells are hexagons stretched sideways. Rows sit
/// one chip-height-plus-gap apart, and each row is shifted half a cell from the rows
/// above and below it, like the cells of a honeycomb (or bricks in a wall). Every
/// cell has six neighbours: one either side, two above and two below. Rows stay level,
/// so a row of chips still reads straight across.
///
/// Cells are named in "doubled" coordinates: `column` counts half cells across and
/// `row` counts rows down, and only cells where `column + row` is even exist. That
/// keeps the maths simple integer steps. Pure and deterministic, like the rest of the
/// map's geometry, so it runs off the main thread and can be unit-tested.
struct MapHex: Hashable {
    let column: Int
    let row: Int

    init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    /// The six neighbours, clockwise from the right.
    static let neighbourSteps: [(dc: Int, dr: Int)] = [(2, 0), (1, 1), (-1, 1), (-2, 0), (-1, -1), (1, -1)]

    /// Steps between neighbouring cells: `step.width` from a cell to the one beside it,
    /// `step.height` from one row to the next (the row is shifted `step.width / 2`).
    struct Lattice: Equatable {
        let step: CGSize

        /// The standard honeycomb: one standard chip plus the clear gap around it.
        static let standard = Lattice(step: MapLayout.pitch)

        /// A honeycomb roomy enough for most of these chips. Large text makes chips
        /// bigger, and then the cells grow with them; a few long titles don't stretch
        /// every cell, they just take a neighbouring cell's room too.
        static func fitting(_ ids: some Sequence<UUID>, sizes: [UUID: CGSize]) -> Lattice {
            let dims = ids.compactMap { id -> CGSize? in
                guard let s = sizes[id], s.width > 1, s.height > 1 else { return nil }
                return s
            }
            guard !dims.isEmpty else { return .standard }
            func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
            let typical = CGSize(width: max(MapLayout.cell.width, median(dims.map(\.width))),
                                 height: max(MapLayout.cell.height, median(dims.map(\.height))))
            // Whole points, so the same chips always give exactly the same cells.
            return Lattice(step: CGSize(width: (typical.width + MapLayout.spacing.width).rounded(.up),
                                        height: (typical.height + MapLayout.spacing.height).rounded(.up)))
        }

        /// The smallest moves that carry a whole group of chips from cells to cells: one
        /// cell across, or two rows down (one row would need a half-cell sideways step too).
        var quantum: CGSize { CGSize(width: step.width, height: step.height * 2) }

        /// The centre of a cell. Cell (0, 0) is at (0, 0).
        func point(_ hex: MapHex) -> CGPoint {
            CGPoint(x: CGFloat(hex.column) * step.width / 2, y: CGFloat(hex.row) * step.height)
        }

        /// The cell whose centre is nearest `p`.
        func hex(near p: CGPoint) -> MapHex {
            // A stray infinite or NaN position mustn't crash the conversion to Int.
            func whole(_ v: CGFloat) -> Int {
                let r = v.rounded()
                return r.isFinite ? Int(max(-1_000_000, min(1_000_000, r))) : 0
            }
            let row = whole(p.y / step.height)
            var best: MapHex?
            var bestDistance = CGFloat.infinity
            // The nearest cell is in the nearest row or a row close by (more rows when
            // the cells are very wide, since then the next row's cell can be nearer).
            let rows = max(1, Int((step.width / 2 / step.height).rounded(.up)))
            for r in (row - rows)...(row + rows) {
                var c = whole(p.x / (step.width / 2))
                if (c + r) % 2 != 0 {
                    // Between two cells of this row: take the nearer one.
                    c += p.x >= CGFloat(c) * step.width / 2 ? 1 : -1
                }
                let candidate = MapHex(column: c, row: r)
                let q = point(candidate)
                let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
                if d < bestDistance - 0.0001 { best = candidate; bestDistance = d }
            }
            return best ?? MapHex(column: 0, row: 0)
        }

        /// Snaps a point to the centre of its nearest cell.
        func snapped(_ p: CGPoint) -> CGPoint { point(hex(near: p)) }

        /// Offsets to every cell within `radius` steps, nearest first (by real distance
        /// on screen, since the cells are wider than they are tall). Ties go clockwise
        /// from the right, so the order never changes.
        func searchOrder(radius: Int) -> [MapHex] {
            var out: [(hex: MapHex, d: CGFloat, angle: CGFloat)] = []
            for r in -radius...radius {
                for c in (-2 * radius)...(2 * radius) where (c + r) % 2 == 0 {
                    let hex = MapHex(column: c, row: r)
                    guard hex.distance(to: MapHex(column: 0, row: 0)) <= radius else { continue }
                    let q = point(hex)
                    var angle = atan2(q.y, q.x)
                    if angle < 0 { angle += 2 * .pi }
                    out.append((hex, q.x * q.x + q.y * q.y, angle))
                }
            }
            out.sort { a, b in
                if abs(a.d - b.d) > 0.01 { return a.d < b.d }
                return a.angle < b.angle
            }
            return out.map(\.hex)
        }
    }

    /// Steps from one cell to another, moving only between neighbours.
    func distance(to other: MapHex) -> Int {
        let dc = abs(column - other.column), dr = abs(row - other.row)
        return dr + max(0, (dc - dr) / 2)
    }

    static func + (a: MapHex, b: MapHex) -> MapHex {
        MapHex(column: a.column + b.column, row: a.row + b.row)
    }
}

extension MapLayout {
    /// How far (in cells) a chip may be sent to find a free cell before it's left
    /// where it was instead. Far beyond anything a tidy map needs.
    static let snapReach = 24

    /// Settles chips into the honeycomb. Each chip takes the free cell nearest to it,
    /// "free" meaning its real size (long titles, large text) fits there without
    /// crowding anything already settled. Chips in `fixed` never move, and the rest
    /// steer around them. The chips closest to a cell already settle first, so the
    /// picture changes as little as it can. Deterministic, and snapping a snapped map
    /// moves nothing.
    ///
    /// `order` settles chips in that order instead (the Honeycomb layout uses it to fill
    /// cells in reading order). Chips not in `positions` are ignored.
    static func snap(_ positions: [UUID: CGPoint], sizes: [UUID: CGSize] = [:], fixed: Set<UUID> = [],
                     lattice: MapHex.Lattice? = nil, order: [UUID]? = nil) -> [UUID: CGPoint] {
        guard !positions.isEmpty else { return positions }
        let lattice = lattice ?? .fitting(positions.keys, sizes: sizes)
        var occupied = Occupancy(sizes: sizes, lattice: lattice)
        var out: [UUID: CGPoint] = [:]

        // Pinned chips stay exactly where they are; everything else steers around them.
        for id in positions.keys.sorted(by: { $0.uuidString < $1.uuidString }) where fixed.contains(id) {
            guard let p = positions[id] else { continue }
            out[id] = p
            occupied.insert(id, at: p)
        }

        let movable = positions.keys.filter { !fixed.contains($0) }
        let queue: [UUID]
        if let order {
            let wanted = Set(movable)
            var seen = Set<UUID>()
            let listed = order.filter { wanted.contains($0) && seen.insert($0).inserted }
            queue = listed + movable.filter { !seen.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        } else {
            // Chips nearest a cell first, so a chip that's nearly in place keeps its cell.
            let offset = Dictionary(uniqueKeysWithValues: movable.map { id -> (UUID, CGFloat) in
                let p = positions[id] ?? .zero
                let q = lattice.snapped(p)
                return (id, (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y))
            })
            queue = movable.sorted { a, b in
                let da = offset[a] ?? 0, db = offset[b] ?? 0
                if abs(da - db) > 0.01 { return da < db }
                return a.uuidString < b.uuidString
            }
        }

        let search = lattice.searchOrder(radius: snapReach)
        for id in queue {
            guard let p = positions[id] else { continue }
            let home = lattice.hex(near: p)
            var spot: CGPoint?
            for step in search {
                let q = lattice.point(home + step)
                if occupied.isFree(id, at: q) { spot = q; break }
            }
            // Nowhere free nearby (a very crowded pinned area): leave it be.
            let settled = spot ?? p
            out[id] = settled
            occupied.insert(id, at: settled)
        }
        return out
    }

    /// Moves one chip to the free cell nearest `point`, steering around everything in
    /// `others`. Nil if no cell within `reach` steps is free.
    static func snapOne(_ id: UUID, near point: CGPoint, others: [UUID: CGPoint], sizes: [UUID: CGSize] = [:],
                        reach: Int = 2) -> CGPoint? {
        let lattice = MapHex.Lattice.fitting(Array(others.keys) + [id], sizes: sizes)
        var occupied = Occupancy(sizes: sizes, lattice: lattice)
        for (other, q) in others where other != id { occupied.insert(other, at: q) }
        let home = lattice.hex(near: point)
        for step in lattice.searchOrder(radius: reach) {
            let q = lattice.point(home + step)
            if occupied.isFree(id, at: q) { return q }
        }
        return nil
    }

    /// The cell one step from `point` in a direction, for moving a chip without
    /// dragging (VoiceOver, Switch Control, keyboards). Left and right go to the cell
    /// beside it. Up and down go to a cell in the next row, alternating sides so that
    /// pressing again and again goes straight up rather than drifting. Skips cells that
    /// are taken, up to a few steps, so a chip can hop past its neighbours.
    static func hexStep(_ id: UUID, from point: CGPoint, dx: Int, dy: Int, others: [UUID: CGPoint],
                        sizes: [UUID: CGSize] = [:]) -> CGPoint {
        let lattice = MapHex.Lattice.fitting(Array(others.keys) + [id], sizes: sizes)
        var occupied = Occupancy(sizes: sizes, lattice: lattice)
        for (other, q) in others where other != id { occupied.insert(other, at: q) }
        var hex = lattice.hex(near: point)
        var first: MapHex?
        for _ in 0..<4 {
            if dy == 0 {
                hex = hex + MapHex(column: 2 * dx.signum(), row: 0)
            } else {
                // Even rows lean right, odd rows lean left: up, up comes back above.
                let lean = hex.row.isMultiple(of: 2) ? 1 : -1
                hex = hex + MapHex(column: lean, row: dy.signum())
            }
            if first == nil { first = hex }
            let q = lattice.point(hex)
            if occupied.isFree(id, at: q) { return q }
        }
        return lattice.point(first ?? hex)
    }

    /// The Honeycomb layout: every chip in one even honeycomb, about as wide as it is
    /// tall on screen, folders followed by their sub-nogs, oldest first. Rows read
    /// straight across, each row shifted half a cell from the one above.
    static func honeycomb(_ items: [Item], sizes: [UUID: CGSize] = [:]) -> [UUID: CGPoint] {
        guard !items.isEmpty else { return [:] }
        let ordered = outlineOrder(items)
        let lattice = MapHex.Lattice.fitting(ordered.map(\.id), sizes: sizes)
        let step = lattice.step
        // Columns so the honeycomb comes out about square on screen.
        let columns = max(1, Int((Double(ordered.count) * Double(step.height / step.width)).squareRoot().rounded(.up)))
        let rows = (ordered.count + columns - 1) / columns
        // Centred on cell (0, 0), so the cells stay on the map's honeycomb.
        let firstRow = -(rows - 1) / 2
        let firstColumn = -(columns - 1)
        var wanted: [UUID: CGPoint] = [:]
        for (i, item) in ordered.enumerated() {
            let row = firstRow + i / columns
            var column = firstColumn + 2 * (i % columns)
            if (column + row) % 2 != 0 { column += 1 }
            wanted[item.id] = lattice.point(MapHex(column: column, row: row))
        }
        // Chips that fit their cell keep it; a long title takes the next free one.
        return snap(wanted, sizes: sizes, lattice: lattice, order: ordered.map(\.id))
    }

    /// Settled chips, bucketed by cell, so checking whether a spot is free only looks
    /// at the chips nearby instead of every chip on the page.
    private struct Occupancy {
        let sizes: [UUID: CGSize]
        let lattice: MapHex.Lattice
        private var buckets: [GridKey: [(id: UUID, at: CGPoint, size: CGSize)]] = [:]
        private var biggest: CGSize

        init(sizes: [UUID: CGSize], lattice: MapHex.Lattice) {
            self.sizes = sizes
            self.lattice = lattice
            biggest = lattice.step
        }

        private var bucket: CGSize { lattice.step }

        mutating func insert(_ id: UUID, at p: CGPoint) {
            let s = MapLayout.size(id, in: sizes)
            biggest = CGSize(width: max(biggest.width, s.width + MapLayout.spacing.width),
                             height: max(biggest.height, s.height + MapLayout.spacing.height))
            buckets[GridKey(p, cell: bucket), default: []].append((id, p, s))
        }

        /// True if chip `id` fits at `p` with the clear gap kept to every settled chip.
        func isFree(_ id: UUID, at p: CGPoint) -> Bool {
            let s = MapLayout.size(id, in: sizes)
            let home = GridKey(p, cell: bucket)
            // Far enough to catch the biggest chip that could reach this spot.
            let rx = Int(((s.width + MapLayout.spacing.width + biggest.width) / 2 / bucket.width).rounded(.up)) + 1
            let ry = Int(((s.height + MapLayout.spacing.height + biggest.height) / 2 / bucket.height).rounded(.up)) + 1
            for gx in (home.x - rx)...(home.x + rx) {
                for gy in (home.y - ry)...(home.y + ry) {
                    for other in buckets[GridKey(x: gx, y: gy)] ?? [] where other.id != id {
                        let ox = (s.width + other.size.width) / 2 + MapLayout.spacing.width - abs(p.x - other.at.x)
                        let oy = (s.height + other.size.height) / 2 + MapLayout.spacing.height - abs(p.y - other.at.y)
                        if ox > 0.5 && oy > 0.5 { return false }
                    }
                }
            }
            return true
        }
    }
}
