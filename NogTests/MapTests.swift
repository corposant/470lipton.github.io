import CoreGraphics
import XCTest
@testable import Nog

final class MapGraphTests: XCTestCase {
    func testGraphCollectsLinesFoldersNeighboursAndZones() {
        var trip = Item(title: "Trip")
        trip.tags = ["travel"]
        var flights = Item(title: "Book flights")
        flights.parentID = trip.id
        var packing = Item(title: "Packing")
        packing.body = "see [[trip]]"
        var bank = Item(title: "Bank", status: .done)
        bank.tags = ["admin"]
        let all = Dictionary(uniqueKeysWithValues: [trip, flights, packing, bank].map { ($0.id, $0) })

        let graph = MapGraph(all: all, page: "", showNogged: false)
        XCTAssertEqual(Set(graph.ids), [trip.id, flights.id, packing.id]) // nogged items hidden
        XCTAssertEqual(graph.folders, [trip.id])
        XCTAssertEqual(graph.neighbours[trip.id], [flights.id, packing.id])
        XCTAssertEqual(graph.progress[trip.id].total, 1)
        // #travel flows down to the sub-item, so its zone wraps both.
        XCTAssertEqual(graph.zoneGroups.map(\.tags), [["travel"]])
        XCTAssertEqual(graph.zoneGroups.first?.members, [trip.id, flights.id])

        // On the #travel page, its own zone would wrap everything, so there isn't one.
        XCTAssertTrue(MapGraph(all: all, page: "travel", showNogged: false).zoneGroups.isEmpty)
    }

    func testFilingTargetsSkipSelfCurrentFolderAndSubItems() {
        let trip = Item(title: "Trip")
        var flights = Item(title: "Book flights")
        flights.parentID = trip.id
        var seat = Item(title: "Pick seat")
        seat.parentID = flights.id
        let admin = Item(title: "Admin")
        let items = [trip, flights, seat, admin]
        let all = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let graph = MapGraph(all: all, page: "", showNogged: false)

        func isDescendant(_ candidate: UUID, _ ancestor: UUID) -> Bool {
            var current = all[candidate]?.parentID
            while let c = current {
                if c == ancestor { return true }
                current = all[c]?.parentID
            }
            return false
        }
        let targets = graph.filingTargets(for: flights.id, isDescendant: isDescendant).map(\.title)
        XCTAssertEqual(targets, ["Admin"]) // not itself, not Trip (already there), not Pick seat (inside it)
    }
}

@MainActor
final class MapGraphCacheTests: XCTestCase {
    func testCacheRebuildsOnlyWhenSomethingChanges() {
        let a = Item(title: "A")
        var all = [a.id: a]
        let cache = MapGraphCache()
        XCTAssertEqual(cache.graph(all, page: "", showNogged: false).ids, [a.id])

        let b = Item(title: "B")
        all[b.id] = b
        XCTAssertEqual(Set(cache.graph(all, page: "", showNogged: false).ids), [a.id, b.id])
    }
}

@MainActor
final class MapChangeTests: XCTestCase {
    func testApplyMovesAndFilesAndTheInverseUndoesIt() throws {
        let store = ItemStore(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                              schedulesNotifications: false)
        let folder = try XCTUnwrap(store.capture("Trip"))
        let item = try XCTUnwrap(store.capture("Book flights"))
        let doc = MapDocument()
        doc.positions[item.id] = CGPoint(x: 10, y: 20)

        let undo = doc.apply(MapChange(spots: [.init(id: item.id, position: CGPoint(x: 300, y: 40))],
                                       filings: [.init(id: item.id, parent: folder.id)]), store: store)
        XCTAssertEqual(doc.positions[item.id], CGPoint(x: 300, y: 40))
        XCTAssertEqual(store.items[item.id]?.parentID, folder.id)

        let redo = doc.apply(undo, store: store)
        XCTAssertEqual(doc.positions[item.id], CGPoint(x: 10, y: 20))
        XCTAssertNil(store.items[item.id]?.parentID)

        doc.apply(redo, store: store)
        XCTAssertEqual(doc.positions[item.id], CGPoint(x: 300, y: 40))
        XCTAssertEqual(store.items[item.id]?.parentID, folder.id)
    }

    func testUndoingAMoveOfAnUnplacedChipForgetsItsSpot() {
        let store = ItemStore(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
                              schedulesNotifications: false)
        let doc = MapDocument()
        let id = UUID()
        let undo = doc.apply(MapChange(spots: [.init(id: id, position: .zero)]), store: store)
        XCTAssertEqual(doc.positions[id], .zero)
        doc.apply(undo, store: store)
        XCTAssertNil(doc.positions[id])
    }
}

final class MapLayoutSizeTests: XCTestCase {
    private func overlaps(_ p: [UUID: CGPoint], sizes: [UUID: CGSize]) -> Bool {
        MapLayout.hasOverlap(p, sizes: sizes)
    }

    func testSeparateUsesMeasuredSizes() {
        let a = UUID(), b = UUID()
        // Standard cells this far apart don't touch; two very wide chips do.
        let p = [a: CGPoint(x: 0, y: 0), b: CGPoint(x: 240, y: 0)]
        XCTAssertFalse(overlaps(p, sizes: [:]))
        let wide = [a: CGSize(width: 400, height: 58), b: CGSize(width: 400, height: 58)]
        XCTAssertTrue(overlaps(p, sizes: wide))
        let fixed = MapLayout.separate(p, sizes: wide)
        XCTAssertFalse(overlaps(fixed, sizes: wide))
    }

    func testSeparateNeverMovesFixedChips() {
        let pinned = UUID(), loose = UUID()
        let p = [pinned: CGPoint(x: 0, y: 0), loose: CGPoint(x: 10, y: 5)]
        let out = MapLayout.separate(p, fixed: [pinned])
        XCTAssertEqual(out[pinned], CGPoint(x: 0, y: 0))
        XCTAssertNotEqual(out[loose], CGPoint(x: 10, y: 5))
        XCTAssertFalse(overlaps(out, sizes: [:]))
    }

    func testPlacingNewItemsKeepsOldOnesAndAvoidsThem() {
        let old = (0..<6).map { _ in UUID() }
        var pinned: [UUID: CGPoint] = [:]
        for (i, id) in old.enumerated() { pinned[id] = CGPoint(x: CGFloat(i % 3) * 230, y: CGFloat(i / 3) * 90) }
        let new = (0..<4).map { _ in UUID() }
        let edges = new.map { MapLayout.Edge(from: old[0], to: $0, kind: .parent) }
        let out = MapLayout.place(missing: new, edges: edges, pinned: pinned)
        for id in old { XCTAssertEqual(out[id], pinned[id]) }
        XCTAssertTrue(new.allSatisfy { out[$0] != nil })
        XCTAssertFalse(overlaps(out, sizes: [:]))
    }

    func testArrangeAvoidsOverlapWithBigChips() {
        var items: [Item] = []
        let trip = Item(title: "Trip")
        items.append(trip)
        for i in 0..<8 { var s = Item(title: "A rather long sub-item title \(i)"); s.parentID = trip.id; items.append(s) }
        for i in 0..<6 { items.append(Item(title: "Loose \(i)")) }
        // Large text: every chip is much bigger than the standard cell.
        let sizes = Dictionary(uniqueKeysWithValues: items.map { ($0.id, CGSize(width: 260, height: 110)) })
        let p = MapLayout.arrange(items, sizes: sizes)
        XCTAssertEqual(p.count, items.count)
        XCTAssertFalse(overlaps(p, sizes: sizes))
    }

    func testArrangePutsLinkedNotesSideBySide() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var items: [Item] = []
        for i in 0..<6 {
            var item = Item(title: "Note \(i)")
            item.created = base.addingTimeInterval(Double(i))
            items.append(item)
        }
        // The first note links to the last; they should end up next to each other on the shelf.
        items[0].body = "see [[Note 5]]"
        let p = MapLayout.arrange(items)
        let first = p[items[0].id]!, last = p[items[5].id]!
        XCTAssertLessThan(hypot(first.x - last.x, first.y - last.y), MapLayout.pitch.width * 1.5)
    }
}

@MainActor
final class MapPlacementTests: XCTestCase {
    func testPlaceMissingFillsOnlyNewItemsAndSettleTidiesThem() async {
        let a = Item(title: "A"), b = Item(title: "B")
        let doc = MapDocument()
        doc.positions[a.id] = CGPoint(x: 0, y: 0)
        await doc.placeMissing([a, b], edges: [], sizes: [:])
        XCTAssertEqual(doc.positions[a.id], CGPoint(x: 0, y: 0))
        XCTAssertNotNil(doc.positions[b.id])
        XCTAssertTrue(doc.unsettled.contains(b.id))

        // B turns out to be huge: settling moves B, never A.
        doc.positions[b.id] = CGPoint(x: 50, y: 0)
        let sizes = [a.id: MapLayout.cell, b.id: CGSize(width: 500, height: 200)]
        await doc.settle(onPage: [a.id, b.id], sizes: sizes)
        XCTAssertEqual(doc.positions[a.id], CGPoint(x: 0, y: 0))
        XCTAssertFalse(MapLayout.hasOverlap(doc.positions, sizes: sizes))
        XCTAssertFalse(doc.unsettled.contains(b.id))
    }
}

final class MapWandTests: XCTestCase {
    private func sampleItems() -> [Item] {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var items: [Item] = []
        var trip = Item(title: "Trip"); trip.tags = ["travel"]; trip.created = base
        items.append(trip)
        for i in 0..<5 {
            var s = Item(title: "Step \(i)"); s.parentID = trip.id; s.created = base.addingTimeInterval(Double(i + 1))
            items.append(s)
        }
        var bank = Item(title: "Bank"); bank.tags = ["admin"]; bank.created = base.addingTimeInterval(10)
        items.append(bank)
        for i in 0..<4 {
            var n = Item(title: "Note \(i)"); n.created = base.addingTimeInterval(Double(20 + i))
            if i == 0 { n.body = "see [[Trip]]" }
            items.append(n)
        }
        return items
    }

    func testEveryStylePlacesEverythingWithoutOverlapAndIsDeterministic() {
        let items = sampleItems()
        for style in MapLayout.Style.allCases {
            let p = MapLayout.layOut(style, items: items)
            XCTAssertEqual(p.count, items.count, "\(style)")
            XCTAssertFalse(MapLayout.hasOverlap(p), "\(style) overlaps")
            XCTAssertEqual(p, MapLayout.layOut(style, items: items), "\(style) not deterministic")
            XCTAssertTrue(p.values.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(style)")
        }
    }

    func testMindMapPutsTheOnlyProjectInTheMiddleWithBranchesOnBothSides() {
        let items = sampleItems().filter { $0.title == "Trip" || $0.title.hasPrefix("Step") }
        let p = MapLayout.mindMap(items)
        let trip = items.first { $0.title == "Trip" }!
        XCTAssertEqual(p[trip.id], .zero)
        let xs = items.filter { $0.id != trip.id }.compactMap { p[$0.id]?.x }
        XCTAssertTrue(xs.contains { $0 > 0 } && xs.contains { $0 < 0 })
    }

    func testTidyUpLeavesPinnedChipsAndFixesOverlaps() {
        let items = sampleItems()
        var positions: [UUID: CGPoint] = [:]
        // Everything piled up in one spot, a step far from its folder.
        for item in items { positions[item.id] = CGPoint(x: 0, y: 0) }
        let trip = items[0], stray = items[1], pinnedNote = items.last!
        positions[stray.id] = CGPoint(x: 3000, y: 0)
        positions[pinnedNote.id] = CGPoint(x: 5, y: 5)

        let out = MapLayout.cleanup(items, positions: positions, pinned: [pinnedNote.id])
        XCTAssertEqual(out[pinnedNote.id], CGPoint(x: 5, y: 5))
        XCTAssertFalse(MapLayout.hasOverlap(out))
        let t = out[trip.id]!, s = out[stray.id]!
        XCTAssertLessThan(hypot(s.x - t.x, s.y - t.y), 1000) // came back near its folder
    }

    func testTidyUpOnATidyMapMovesNothing() {
        let items = sampleItems()
        let tidy = MapLayout.cleanup(items, positions: MapLayout.arrange(items), pinned: [])
        XCTAssertEqual(MapLayout.cleanup(items, positions: tidy, pinned: []), tidy)
    }

    func testZonesThatShareNothingArePulledApart() {
        let a = (0..<3).map { _ in UUID() }, b = (0..<3).map { _ in UUID() }
        var p: [UUID: CGPoint] = [:]
        for (i, id) in a.enumerated() { p[id] = CGPoint(x: CGFloat(i) * 230, y: 0) }
        for (i, id) in b.enumerated() { p[id] = CGPoint(x: CGFloat(i) * 230 + 100, y: 90) }
        let out = MapLayout.separateZones(p, zones: [Set(a), Set(b)])
        func box(_ ids: [UUID]) -> CGRect {
            ids.reduce(CGRect.null) { r, id in
                let q = out[id]!
                return r.union(CGRect(x: q.x - 98, y: q.y - 29, width: 196, height: 58))
            }
        }
        XCTAssertFalse(box(a).insetBy(dx: -30, dy: -30).intersects(box(b).insetBy(dx: -30, dy: -30)))
    }
}

final class MapFlockTests: XCTestCase {
    func testFlightLandsExactlyOnTheTargets() {
        let a = UUID(), b = UUID(), still = UUID()
        let start = [a: CGPoint(x: 0, y: 0), b: CGPoint(x: 10, y: 0), still: CGPoint(x: 500, y: 500)]
        let targets = [a: CGPoint(x: 800, y: 300), b: CGPoint(x: -600, y: 200), still: CGPoint(x: 500, y: 500)]
        var flock = MapFlock(from: start, to: targets, groups: [a: 0, b: 0])
        XCTAssertNil(flock.positions[still]) // not moving, not flying
        var steps = 0
        flock.step(1.0 / 60)
        XCTAssertNotEqual(flock.positions[a], start[a])
        while !flock.isFinished && steps < 1000 {
            flock.step(1.0 / 60)
            steps += 1
        }
        XCTAssertTrue(flock.isFinished)
        XCTAssertEqual(flock.positions[a]!.x, 800, accuracy: 0.001)
        XCTAssertEqual(flock.positions[a]!.y, 300, accuracy: 0.001)
        XCTAssertEqual(flock.positions[b]!.x, -600, accuracy: 0.001)
        XCTAssertEqual(flock.positions[b]!.y, 200, accuracy: 0.001)
    }

    func testSameStepsSameFlight() {
        let ids = (0..<8).map { _ in UUID() }
        var start: [UUID: CGPoint] = [:], targets: [UUID: CGPoint] = [:]
        for (i, id) in ids.enumerated() {
            start[id] = CGPoint(x: CGFloat(i) * 5, y: 0)
            targets[id] = CGPoint(x: CGFloat(i) * 220, y: 300)
        }
        var one = MapFlock(from: start, to: targets), two = MapFlock(from: start, to: targets)
        for _ in 0..<20 { one.step(1.0 / 60); two.step(1.0 / 60) }
        XCTAssertEqual(one.positions, two.positions)
    }
}

/// Big pages: an import of hundreds of nogs must lay out quickly and tidily.
final class MapBigPageTests: XCTestCase {
    private func bigPage(_ count: Int) -> [Item] {
        var items: [Item] = []
        let tags = ["home", "work", "calls", "errands"]
        for i in 0..<count {
            var item = Item(title: "Test item \(i)", created: Date(timeIntervalSince1970: Double(i)))
            item.tags = ["perftest", tags[i % tags.count]]
            if i % 5 == 1, let parent = items.last(where: { $0.parentID == nil }) { item.parentID = parent.id }
            items.append(item)
        }
        return items
    }

    func testThreeHundredItemsArrangeWithoutOverlap() {
        let items = bigPage(300)
        let p = MapLayout.arrange(items)
        XCTAssertEqual(p.count, 300)
        XCTAssertTrue(p.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertFalse(MapLayout.hasOverlap(p))
    }

    func testBulkPlacementGoesBesideTheExistingMap() {
        let old = bigPage(10)
        let existing = MapLayout.arrange(old)
        let new = bigPage(60).suffix(50).map { item -> Item in
            var copy = Item(title: item.title, created: item.created)
            copy.tags = item.tags
            return copy
        }
        let out = MapLayout.placeBeside(Array(new), existing: existing)
        XCTAssertEqual(out.count, 50)
        let oldRight = existing.values.map(\.x).max() ?? 0
        XCTAssertTrue(out.values.allSatisfy { $0.x > oldRight })
        var all = existing
        all.merge(out) { a, _ in a }
        XCTAssertFalse(MapLayout.hasOverlap(all))
    }

    func testWebLayoutHandlesABigPage() {
        let items = bigPage(300)
        let p = MapLayout.layOut(.web, items: items)
        XCTAssertEqual(p.count, 300)
        XCTAssertTrue(p.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testSeparateOnABigCrowdedPage() {
        // 300 chips scattered so that many overlap, deterministically.
        var p: [UUID: CGPoint] = [:]
        var seed = 12345
        func next() -> CGFloat {
            seed = (seed * 1_103_515_245 + 12345) % 2_147_483_648
            return CGFloat(seed % 4000)
        }
        for _ in 0..<300 {
            let x = next(), y = next()
            p[UUID()] = CGPoint(x: x, y: y)
        }
        XCTAssertTrue(MapLayout.hasOverlap(p))
        let out = MapLayout.separate(p, iterations: 400)
        XCTAssertEqual(out.count, 300)
        XCTAssertFalse(MapLayout.hasOverlap(out))
    }

    private func extent(_ p: [UUID: CGPoint]) -> CGRect {
        p.values.reduce(CGRect.null) { $0.union(CGRect(x: $1.x - 98, y: $1.y - 29, width: 196, height: 58)) }
    }

    func testBigLayoutsAreRoughlySquareNotLongColumns() {
        let items = bigPage(300)
        for style in MapLayout.Style.allCases {
            let r = extent(MapLayout.layOut(style, items: items))
            let ratio = r.width / r.height
            XCTAssertTrue(ratio > 0.25 && ratio < 4, "\(style.title) is \(Int(r.width)) × \(Int(r.height))")
        }
    }

    func testTidyUpOnABigPageDoesNotSprawl() {
        let items = bigPage(300)
        let graph = MapGraph(all: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }), page: "", showNogged: true)
        let start = MapLayout.arrange(items)
        let out = MapLayout.cleanup(items, positions: start, pinned: [], zones: graph.zoneGroups.map(\.members))
        XCTAssertFalse(MapLayout.hasOverlap(out))
        let before = extent(start), after = extent(out)
        XCTAssertLessThanOrEqual(after.width * after.height, before.width * before.height * 1.5)
    }

    func testTidyingTwiceMovesNothingTheSecondTime() {
        let items = bigPage(300)
        let graph = MapGraph(all: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }), page: "", showNogged: true)
        let zones = graph.zoneGroups.map(\.members)
        // Start from a mess: the tidy layout, with every third chip thrown somewhere else.
        var start = MapLayout.arrange(items)
        for (i, item) in items.enumerated() where i % 3 == 0 {
            start[item.id] = CGPoint(x: CGFloat((i * 7919) % 3000), y: CGFloat((i * 104_729) % 3000))
        }
        let once = MapLayout.cleanup(items, positions: start, pinned: [], zones: zones)
        let twice = MapLayout.cleanup(items, positions: once, pinned: [], zones: zones)
        XCTAssertEqual(once, twice)
    }
}

final class MapSqueezeTests: XCTestCase {
    func testSqueezeClosesWideGapsAndKeepsPins() {
        let a = UUID(), b = UUID(), c = UUID()
        let p = [a: CGPoint(x: 0, y: 0), b: CGPoint(x: 3000, y: 0), c: CGPoint(x: 3000, y: 4000)]
        let out = MapLayout.squeeze(p, fixed: [a])
        XCTAssertEqual(out[a], CGPoint(x: 0, y: 0))
        // b's left edge now sits maxGap past a's right edge.
        XCTAssertEqual(out[b]!.x - 98 - (0 + 98), MapLayout.maxGap, accuracy: 0.01)
        XCTAssertEqual(out[c]!.y - 29 - (0 + 29), MapLayout.maxGap, accuracy: 0.01)
        XCTAssertFalse(MapLayout.hasOverlap(out))
        // Already compact: nothing moves.
        XCTAssertEqual(MapLayout.squeeze(out, fixed: [a]), out)
    }

    func testSqueezeLeavesAGapWithPinsOnBothSides() {
        let a = UUID(), b = UUID()
        let p = [a: CGPoint(x: 0, y: 0), b: CGPoint(x: 3000, y: 0)]
        XCTAssertEqual(MapLayout.squeeze(p, fixed: [a, b]), p)
    }
}


final class MapHexTests: XCTestCase {
    private let lattice = MapHex.Lattice.standard

    private func onLattice(_ p: CGPoint, _ lattice: MapHex.Lattice = .standard) -> Bool {
        lattice.snapped(p) == p
    }

    /// A deterministic scatter of `count` chips over a square `span` points wide.
    private func scatter(_ count: Int, span: Int = 3000) -> [UUID: CGPoint] {
        var seed = 4242
        func next() -> CGFloat {
            seed = (seed * 1_103_515_245 + 12345) % 2_147_483_648
            return CGFloat(seed % span) - CGFloat(span / 2)
        }
        var p: [UUID: CGPoint] = [:]
        for _ in 0..<count { p[UUID()] = CGPoint(x: next(), y: next()) }
        return p
    }

    func testCellsHaveSixNeighboursAndRowsAreOffsetByHalfACell() {
        let origin = MapHex(column: 0, row: 0)
        XCTAssertEqual(lattice.point(origin), .zero)
        for step in MapHex.neighbourSteps {
            XCTAssertEqual(origin.distance(to: MapHex(column: step.dc, row: step.dr)), 1)
        }
        // The cell beside is one cell across; the cells above are half a cell across.
        XCTAssertEqual(lattice.point(MapHex(column: 2, row: 0)).x, MapLayout.pitch.width)
        XCTAssertEqual(lattice.point(MapHex(column: 1, row: 1)), CGPoint(x: MapLayout.pitch.width / 2, y: MapLayout.pitch.height))
        // Standard chips in neighbouring cells never overlap.
        var p: [UUID: CGPoint] = [UUID(): .zero]
        for step in MapHex.neighbourSteps { p[UUID()] = lattice.point(MapHex(column: step.dc, row: step.dr)) }
        XCTAssertFalse(MapLayout.hasOverlap(p))
    }

    func testNearestCellIsReallyTheNearest() {
        for p in scatter(200).values {
            let q = lattice.snapped(p)
            let best = lattice.searchOrder(radius: 2).map { lattice.point(lattice.hex(near: q) + $0) }
                .map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? 0
            XCTAssertEqual(hypot(q.x - p.x, q.y - p.y), best, accuracy: 0.01)
        }
    }

    func testSnapPutsEveryChipInAFreeCellAndIsStable() {
        var p = scatter(150)
        // Half of them piled up on one spot.
        for id in p.keys.sorted(by: { $0.uuidString < $1.uuidString }).prefix(40) { p[id] = CGPoint(x: 10, y: 10) }
        let out = MapLayout.snap(p)
        XCTAssertEqual(out.count, p.count)
        XCTAssertFalse(MapLayout.hasOverlap(out))
        XCTAssertTrue(out.values.allSatisfy { onLattice($0) })
        XCTAssertEqual(MapLayout.snap(out), out)
    }

    func testSnapWithBigChipsKeepsThemApart() {
        let p = scatter(80, span: 1500)
        var sizes: [UUID: CGSize] = [:]
        for (i, id) in p.keys.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
            sizes[id] = i % 4 == 0 ? CGSize(width: 420, height: 110) : CGSize(width: 196, height: 58)
        }
        let out = MapLayout.snap(p, sizes: sizes)
        XCTAssertFalse(MapLayout.hasOverlap(out, sizes: sizes))
        XCTAssertEqual(MapLayout.snap(out, sizes: sizes), out)
    }

    func testSnapNeverMovesPinnedChipsAndSteersAroundThem() {
        let pinned = UUID(), loose = UUID()
        let p = [pinned: CGPoint(x: 13, y: 7), loose: CGPoint(x: 20, y: 0)]
        let out = MapLayout.snap(p, fixed: [pinned])
        XCTAssertEqual(out[pinned], CGPoint(x: 13, y: 7))
        XCTAssertTrue(onLattice(out[loose]!))
        XCTAssertFalse(MapLayout.hasOverlap(out))
    }

    func testLargeTextMakesBiggerCells() {
        let ids = (0..<5).map { _ in UUID() }
        let big = Dictionary(uniqueKeysWithValues: ids.map { ($0, CGSize(width: 300, height: 100)) })
        let roomy = MapHex.Lattice.fitting(ids, sizes: big)
        XCTAssertEqual(roomy.step.width, 300 + MapLayout.spacing.width)
        XCTAssertEqual(roomy.step.height, 100 + MapLayout.spacing.height)
        XCTAssertEqual(MapHex.Lattice.fitting(ids, sizes: [:]), .standard)
    }

    func testHoneycombLayoutOffsetsEveryOtherRow() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (0..<20).map { i -> Item in
            var item = Item(title: "Nog \(i)")
            item.created = base.addingTimeInterval(Double(i))
            return item
        }
        let p = MapLayout.layOut(.grid, items: items)
        XCTAssertEqual(p.count, 20)
        XCTAssertFalse(MapLayout.hasOverlap(p))
        XCTAssertTrue(p.values.allSatisfy { onLattice($0) })
        // Reading order: the first row is level, and the second row starts half a cell over.
        let rows = Dictionary(grouping: items.compactMap { p[$0.id] }, by: \.y).keys.sorted()
        XCTAssertGreaterThan(rows.count, 1)
        let first = p.values.filter { $0.y == rows[0] }.map(\.x).min()!
        let second = p.values.filter { $0.y == rows[1] }.map(\.x).min()!
        XCTAssertEqual(abs(second - first), MapLayout.pitch.width / 2, accuracy: 0.01)
        XCTAssertEqual(p[items[0].id]?.x, first)
        XCTAssertEqual(p[items[0].id]?.y, rows[0])
    }

    func testEveryLayoutAndTidyUpLandsInTheHoneycomb() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var items: [Item] = []
        let trip = Item(title: "Trip")
        items.append(trip)
        for i in 0..<9 {
            var s = Item(title: "Step \(i)")
            s.parentID = trip.id
            s.created = base.addingTimeInterval(Double(i))
            items.append(s)
        }
        for i in 0..<8 { items.append(Item(title: "Loose \(i)")) }
        for style in MapLayout.Style.allCases {
            let p = MapLayout.layOut(style, items: items)
            XCTAssertTrue(p.values.allSatisfy { onLattice($0) }, "\(style.title) is off the honeycomb")
            XCTAssertFalse(MapLayout.hasOverlap(p), "\(style.title)")
        }
        var messy: [UUID: CGPoint] = [:]
        for (i, item) in items.enumerated() { messy[item.id] = CGPoint(x: CGFloat(i * 37 % 500), y: CGFloat(i * 53 % 400)) }
        let tidy = MapLayout.cleanup(items, positions: messy, pinned: [])
        XCTAssertTrue(tidy.values.allSatisfy { onLattice($0) })
        XCTAssertFalse(MapLayout.hasOverlap(tidy))
        XCTAssertEqual(MapLayout.cleanup(items, positions: tidy, pinned: []), tidy)
    }

    func testDroppingSnapsToTheNearestFreeCell() {
        let a = UUID(), b = UUID()
        let others = [a: CGPoint.zero]
        // Dropped almost on top of a: it goes beside it, not on it.
        let spot = MapLayout.snapOne(b, near: CGPoint(x: 30, y: 10), others: others)
        XCTAssertNotNil(spot)
        XCTAssertTrue(onLattice(spot!))
        XCTAssertFalse(MapLayout.hasOverlap([a: .zero, b: spot!]))
        // Dropped in open space: the nearest cell.
        XCTAssertEqual(MapLayout.snapOne(b, near: CGPoint(x: 1010, y: 410), others: others),
                       lattice.snapped(CGPoint(x: 1010, y: 410)))
    }

    func testStepsMoveOneCellAndHopOverNeighbours() {
        let me = UUID(), right = UUID()
        let start = CGPoint.zero
        let w = MapLayout.pitch.width, h = MapLayout.pitch.height
        XCTAssertEqual(MapLayout.hexStep(me, from: start, dx: -1, dy: 0, others: [:]), CGPoint(x: -w, y: 0))
        // Something in the next cell: hop to the one after it.
        XCTAssertEqual(MapLayout.hexStep(me, from: start, dx: 1, dy: 0, others: [right: CGPoint(x: w, y: 0)]),
                       CGPoint(x: 2 * w, y: 0))
        // Up twice comes back straight above.
        let up = MapLayout.hexStep(me, from: start, dx: 0, dy: -1, others: [:])
        XCTAssertEqual(up.y, -h)
        XCTAssertEqual(abs(up.x), w / 2)
        let upAgain = MapLayout.hexStep(me, from: up, dx: 0, dy: -1, others: [:])
        XCTAssertEqual(upAgain, CGPoint(x: 0, y: -2 * h))
    }

    func testWholeCellSqueezeKeepsChipsInTheHoneycomb() {
        let a = UUID(), b = UUID()
        let p = [a: lattice.point(MapHex(column: 0, row: 0)), b: lattice.point(MapHex(column: 30, row: 0))]
        let out = MapLayout.squeeze(p, quantum: lattice.quantum)
        XCTAssertLessThan(out[b]!.x - out[a]!.x, p[b]!.x - p[a]!.x)
        XCTAssertTrue(out.values.allSatisfy { onLattice($0) })
        XCTAssertFalse(MapLayout.hasOverlap(out))
    }
}
