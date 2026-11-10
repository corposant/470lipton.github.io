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
