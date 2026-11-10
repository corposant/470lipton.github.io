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
