import CoreGraphics
import Foundation
import Observation
import PencilKit

/// Lazily creates one map document per page ("" = All, otherwise a tag).
@MainActor
@Observable
final class MapPages {
    @ObservationIgnored private var docs: [String: MapDocument] = [:]

    func doc(for page: String) -> MapDocument {
        if let doc = docs[page] { return doc }
        let doc = MapDocument(page: page)
        docs[page] = doc
        return doc
    }
}

/// Where each node sits on one map page, and what you've scribbled on it.
/// Saved beside the items (`_nogmap.json` for All, `_nogmap-<tag>.json` per tag),
/// so it syncs through iCloud too.
@MainActor
@Observable
final class MapDocument {
    let page: String

    init(page: String = "") {
        self.page = page.lowercased()
    }

    var fileName: String {
        guard !page.isEmpty else { return "_nogmap.json" }
        let slug = page.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
        return "_nogmap-\(slug).json"
    }

    var positions: [UUID: CGPoint] = [:]
    private(set) var drawing = PKDrawing()
    /// Goes up whenever `drawing` changes, so views can tell cheaply (comparing
    /// two drawings means comparing every stroke).
    private(set) var drawingVersion = 0

    @ObservationIgnored private weak var store: ItemStore?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private struct Stored: Codable {
        var positions: [String: [Double]]
        var drawing: Data?
    }

    @ObservationIgnored private var loadedFolder: URL?

    /// Loads once per storage folder (re-opening the map doesn't undo unsaved moves).
    func load(from store: ItemStore) {
        guard loadedFolder != store.folder else { return }
        loadedFolder = store.folder
        self.store = store
        guard let data = store.readSidecar(fileName),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        var loaded: [UUID: CGPoint] = [:]
        for (key, xy) in stored.positions where xy.count == 2 {
            if let id = UUID(uuidString: key) { loaded[id] = CGPoint(x: xy[0], y: xy[1]) }
        }
        positions = loaded
        if let drawingData = stored.drawing, let decoded = try? PKDrawing(data: drawingData) {
            drawing = decoded
            drawingVersion += 1
        }
    }

    /// Debounced save.
    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            let stored = Stored(
                positions: Dictionary(uniqueKeysWithValues: self.positions.map { ($0.key.uuidString, [Double($0.value.x), Double($0.value.y)]) }),
                drawing: self.drawing.strokes.isEmpty ? nil : self.drawing.dataRepresentation())
            if let data = try? JSONEncoder().encode(stored) {
                store.writeSidecar(self.fileName, data: data)
            }
        }
    }

    /// A new tag page starts from where its items sit on All, so it looks familiar.
    func seedIfEmpty(from other: MapDocument, ids: [UUID]) {
        guard positions.isEmpty else { return }
        for id in ids { if let p = other.positions[id] { positions[id] = p } }
        if !positions.isEmpty { save() }
    }

    /// Places any items that don't have a spot yet, near what they're connected to.
    func placeMissing(_ items: [Item], edges: [MapLayout.Edge]) {
        let ids = items.map(\.id)
        guard ids.contains(where: { positions[$0] == nil }) else { return }
        // A brand-new page gets the full smart arrangement.
        if positions.isEmpty {
            positions = MapLayout.arrange(items)
            save()
            return
        }
        let pinned = positions.filter { ids.contains($0.key) }
        let laidOut = MapLayout.layout(ids: ids, edges: edges, pinned: pinned)
        for id in ids where positions[id] == nil { positions[id] = laidOut[id] }
        save()
    }

    /// Re-arranges everything from scratch.
    func tidy(_ items: [Item], edges: [MapLayout.Edge]) {
        positions = MapLayout.arrange(items)
        save()
    }

    /// Applies an undoable change and returns the change that undoes it.
    @discardableResult
    func apply(_ change: MapChange, store: ItemStore) -> MapChange {
        var inverse = MapChange()
        for spot in change.spots {
            inverse.spots.append(.init(id: spot.id, position: positions[spot.id]))
            positions[spot.id] = spot.position
        }
        if !change.filings.isEmpty {
            store.batch {
                for filing in change.filings {
                    guard var item = store.items[filing.id] else { continue }
                    inverse.filings.append(.init(id: filing.id, parent: item.parentID))
                    item.parentID = filing.parent
                    store.update(item)
                }
            }
        }
        if !change.spots.isEmpty { save() }
        // Undo in the reverse order, in case one change touched the same item twice.
        inverse.spots.reverse()
        inverse.filings.reverse()
        return inverse
    }

    func move(_ id: UUID, to point: CGPoint) {
        positions[id] = point
        save()
    }

    func setDrawing(_ newDrawing: PKDrawing) {
        guard newDrawing != drawing else { return }
        drawing = newDrawing
        drawingVersion += 1
        save()
    }
}
