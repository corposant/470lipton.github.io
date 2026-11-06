import CoreGraphics
import Foundation
import Observation
import PencilKit

/// Where each node sits on the mind map, and what you've scribbled on it.
/// Saved as `_nogmap.json` beside the items, so it syncs through iCloud too.
@MainActor
@Observable
final class MapDocument {
    static let fileName = "_nogmap.json"

    var positions: [UUID: CGPoint] = [:]
    var drawing = PKDrawing()

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
        guard let data = store.readSidecar(Self.fileName),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        var loaded: [UUID: CGPoint] = [:]
        for (key, xy) in stored.positions where xy.count == 2 {
            if let id = UUID(uuidString: key) { loaded[id] = CGPoint(x: xy[0], y: xy[1]) }
        }
        positions = loaded
        if let drawingData = stored.drawing, let decoded = try? PKDrawing(data: drawingData) {
            drawing = decoded
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
                store.writeSidecar(Self.fileName, data: data)
            }
        }
    }

    /// Places any items that don't have a spot yet, near what they're connected to.
    func placeMissing(_ items: [Item], edges: [MapLayout.Edge]) {
        let ids = items.map(\.id)
        guard ids.contains(where: { positions[$0] == nil }) else { return }
        let pinned = positions.filter { ids.contains($0.key) }
        let laidOut = MapLayout.layout(ids: ids, edges: edges, pinned: pinned)
        for id in ids where positions[id] == nil { positions[id] = laidOut[id] }
        save()
    }

    /// Re-arranges everything from scratch.
    func tidy(_ items: [Item], edges: [MapLayout.Edge]) {
        positions = MapLayout.layout(ids: items.map(\.id), edges: edges, pinned: [:])
        save()
    }

    func move(_ id: UUID, to point: CGPoint) {
        positions[id] = point
        save()
    }

    func setDrawing(_ newDrawing: PKDrawing) {
        guard newDrawing != drawing else { return }
        drawing = newDrawing
        save()
    }
}
