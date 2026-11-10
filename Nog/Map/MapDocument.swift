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
    /// True from a change until it's written, so a reload from disk can't undo it.
    @ObservationIgnored private var hasPendingSave = false
    /// When we last read or wrote the file; anything newer came from another device.
    @ObservationIgnored private var lastSync = Date.distantPast
    /// Chips placed automatically before their real size was known; `settle` tidies them.
    @ObservationIgnored private(set) var unsettled: Set<UUID> = []
    /// Bumped by each placement, so a slower, older one is dropped.
    @ObservationIgnored private var generation = 0

    /// Chips placed by hand. Tidy up never moves them (full layouts do, and unpin them).
    private(set) var pinned: Set<UUID> = []

    private struct Stored: Codable {
        var positions: [String: [Double]]
        var drawing: Data?
        /// Missing in files from before pinning existed.
        var pinned: [String]?
    }

    @ObservationIgnored private var loadedFolder: URL?

    /// Loads once per storage folder (re-opening the map doesn't undo unsaved moves).
    func load(from store: ItemStore) {
        guard loadedFolder != store.folder else { return }
        loadedFolder = store.folder
        self.store = store
        read(from: store)
    }

    /// Picks up the map file if another device changed it (iCloud), unless there are
    /// changes here still waiting to be saved.
    func refreshFromDisk() {
        guard let store, loadedFolder == store.folder, !hasPendingSave else { return }
        let url = store.folder.appending(path: fileName)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified.timeIntervalSince(lastSync) > 5 else { return }
        read(from: store)
    }

    private func read(from store: ItemStore) {
        lastSync = .now
        guard let data = store.readSidecar(fileName),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        var loaded: [UUID: CGPoint] = [:]
        for (key, xy) in stored.positions where xy.count == 2 {
            if let id = UUID(uuidString: key) { loaded[id] = CGPoint(x: xy[0], y: xy[1]) }
        }
        if loaded != positions { positions = loaded }
        unsettled = unsettled.filter { loaded[$0] != nil }
        let loadedPins = Set((stored.pinned ?? []).compactMap(UUID.init(uuidString:)))
        if loadedPins != pinned { pinned = loadedPins }
        let decoded = stored.drawing.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        if decoded.dataRepresentation() != drawing.dataRepresentation() {
            drawing = decoded
            drawingVersion += 1
        }
    }

    /// Debounced save. Spots of items that no longer exist anywhere are dropped.
    func save() {
        hasPendingSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            self.pruneDeleted(store)
            let stored = Stored(
                positions: Dictionary(uniqueKeysWithValues: self.positions.map { ($0.key.uuidString, [Double($0.value.x), Double($0.value.y)]) }),
                drawing: self.drawing.strokes.isEmpty ? nil : self.drawing.dataRepresentation(),
                pinned: self.pinned.isEmpty ? nil : self.pinned.map(\.uuidString).sorted())
            if let data = try? JSONEncoder().encode(stored) {
                store.writeSidecar(self.fileName, data: data)
            }
            self.lastSync = .now
            self.hasPendingSave = false
        }
    }

    /// Forgets the spots of deleted items. An item missing from memory is only treated
    /// as deleted when its file is gone from the folder too, so items still downloading
    /// from iCloud (or not loaded yet) keep their place.
    private func pruneDeleted(_ store: ItemStore) {
        let missing = positions.keys.filter { store.items[$0] == nil }
        guard !missing.isEmpty, !store.items.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: store.folder.path) else { return }
        let listing = names.joined(separator: "\n")
        for id in missing where !listing.contains(id.uuidString) {
            positions[id] = nil
            unsettled.remove(id)
            pinned.remove(id)
        }
    }

    /// A new tag page starts from where its items sit on All, so it looks familiar.
    func seedIfEmpty(from other: MapDocument, ids: [UUID]) {
        guard positions.isEmpty else { return }
        for id in ids { if let p = other.positions[id] { positions[id] = p } }
        if !positions.isEmpty { save() }
    }

    /// Places any items that don't have a spot yet, near what they're connected to,
    /// without moving anything that's already placed. A brand-new page gets the full
    /// smart arrangement. Worked out off the main thread.
    func placeMissing(_ items: [Item], edges: [MapLayout.Edge], sizes: [UUID: CGSize]) async {
        let ids = items.map(\.id)
        let missing = ids.filter { positions[$0] == nil }
        guard !missing.isEmpty else { return }
        generation += 1
        let mine = generation
        let onPage = Set(ids)
        let placed = positions.filter { onPage.contains($0.key) }
        let result = await Task.detached(priority: .userInitiated) { () -> [UUID: CGPoint] in
            placed.isEmpty
                ? MapLayout.arrange(items, sizes: sizes)
                : MapLayout.place(missing: missing, edges: edges, pinned: placed, sizes: sizes)
        }.value
        guard mine == generation else { return }
        var placed = false
        for id in missing where positions[id] == nil {
            guard let p = result[id] else { continue }
            positions[id] = p
            if sizes[id] == nil { unsettled.insert(id) }
            placed = true
        }
        if placed { save() }
    }

    /// Once chips have been measured, nudges the ones that were placed automatically
    /// (with a guessed size) so none overlap. Nothing you placed by hand moves.
    func settle(onPage ids: Set<UUID>, sizes: [UUID: CGSize]) async {
        let moving = unsettled.intersection(ids).filter { sizes[$0] != nil }
        guard !moving.isEmpty else { return }
        let current = positions.filter { ids.contains($0.key) }
        let fixed = Set(current.keys).subtracting(moving)
        let result = await Task.detached(priority: .utility) {
            MapLayout.separate(current, sizes: sizes, fixed: fixed)
        }.value
        unsettled.subtract(moving)
        var changed = false
        for id in moving {
            // Skip anything that moved meanwhile.
            guard let p = result[id], let before = current[id], positions[id] == before, p != before else { continue }
            positions[id] = p
            changed = true
        }
        if changed { save() }
    }

    /// Applies an undoable change and returns the change that undoes it.
    @discardableResult
    func apply(_ change: MapChange, store: ItemStore) -> MapChange {
        var inverse = MapChange()
        for spot in change.spots {
            inverse.spots.append(.init(id: spot.id, position: positions[spot.id]))
            positions[spot.id] = spot.position
            unsettled.remove(spot.id) // placed on purpose now
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
        for pin in change.pins {
            inverse.pins.append(.init(id: pin.id, pinned: pinned.contains(pin.id)))
            if pin.pinned { pinned.insert(pin.id) } else { pinned.remove(pin.id) }
        }
        if !change.spots.isEmpty || !change.pins.isEmpty { save() }
        // Undo in the reverse order, in case one change touched the same item twice.
        inverse.spots.reverse()
        inverse.filings.reverse()
        inverse.pins.reverse()
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
