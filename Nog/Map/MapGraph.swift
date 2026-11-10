import CoreGraphics
import Foundation

/// Everything the map draws that depends only on the items: not on pan, zoom or
/// where the chips sit. Worked out once per change to the items, so panning and
/// zooming (which redraw every frame) don't redo it.
struct MapGraph {
    /// Tags that wrap exactly the same items share one zone ("#HOME · #CALLS").
    struct ZoneGroup {
        let tags: [String]
        let members: Set<UUID>
        var id: String { tags.joined(separator: "+") }
    }

    /// The items on this page, oldest first.
    let items: [Item]
    let ids: [UUID]
    let byID: [UUID: Item]
    let edges: [MapLayout.Edge]
    /// Items with sub-items on this page.
    let folders: Set<UUID>
    /// Sub-item progress, counted across every item.
    let progress: ChildStats
    /// Items joined to each item by a line (either direction).
    let neighbours: [UUID: Set<UUID>]
    /// One group per zone, smallest first.
    let zoneGroups: [ZoneGroup]

    init(all: [UUID: Item], page: String, showNogged: Bool) {
        let values = Array(all.values)
        items = MapPage.items(values, page: page, showNogged: showNogged).sorted { $0.created < $1.created }
        ids = items.map(\.id)
        byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        edges = MapLayout.edges(for: items)
        folders = Set(items.compactMap(\.parentID))
        progress = ChildStats(values)

        var links: [UUID: Set<UUID>] = [:]
        for edge in edges {
            links[edge.from, default: []].insert(edge.to)
            links[edge.to, default: []].insert(edge.from)
        }
        neighbours = links

        // Tags flow down, so a zone wraps a whole project with its sub-items.
        // On a tag's own page, its zone would just surround everything, so skip it.
        let pageTag = page.lowercased()
        var members: [String: Set<UUID>] = [:]
        for item in items {
            for tag in MapPage.effectiveTags(item, in: all) where tag != pageTag {
                members[tag, default: []].insert(item.id)
            }
        }
        var byMembers: [Set<UUID>: [String]] = [:]
        for (tag, ids) in members { byMembers[ids, default: []].append(tag) }
        zoneGroups = byMembers
            .map { ZoneGroup(tags: $0.value.sorted(), members: $0.key) }
            .sorted { ($0.members.count, $0.id) < ($1.members.count, $1.id) }
    }

    /// Folders `id` could be filed into: anything else on the page except its own
    /// sub-items (that would make a loop) and the folder it's already in.
    func filingTargets(for id: UUID, isDescendant: (UUID, UUID) -> Bool) -> [Item] {
        let current = byID[id]?.parentID
        return items
            .filter { $0.id != id && $0.id != current && !isDescendant($0.id, id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// Keeps the last `MapGraph` and rebuilds it only when the items, page or filter change.
///
/// `store.items` is compared with `==`, which is instant when nothing has been
/// written (the dictionary's storage is shared), so a pan frame costs almost nothing.
@MainActor
final class MapGraphCache {
    private var items: [UUID: Item]?
    private var page = ""
    private var showNogged = false
    private var cached: MapGraph?

    func graph(_ all: [UUID: Item], page: String, showNogged: Bool) -> MapGraph {
        if let cached, items == all, self.page == page, self.showNogged == showNogged {
            return cached
        }
        let graph = MapGraph(all: all, page: page, showNogged: showNogged)
        items = all
        self.page = page
        self.showNogged = showNogged
        cached = graph
        return graph
    }
}

/// An undoable change to the map: where chips sit, and which folder items are in.
/// Applying one returns the change that undoes it.
struct MapChange {
    struct Spot {
        let id: UUID
        /// nil = no saved spot (the map places it again).
        let position: CGPoint?
    }

    struct Filing {
        let id: UUID
        /// nil = not in a folder.
        let parent: UUID?
    }

    /// A chip you placed by hand is pinned: Tidy up leaves it where it is.
    struct Pin {
        let id: UUID
        let pinned: Bool
    }

    var spots: [Spot] = []
    var filings: [Filing] = []
    var pins: [Pin] = []

    var isEmpty: Bool { spots.isEmpty && filings.isEmpty && pins.isEmpty }
}

/// Each chip's size as drawn (unzoomed), so layouts can use real sizes: long titles
/// and large text sizes need more room than the standard cell.
///
/// Not observed: a measurement never needs to redraw the map by itself.
@MainActor
final class ChipSizes {
    private(set) var sizes: [UUID: CGSize] = [:]
    private var pending: Task<Void, Never>?

    /// Records a measurement; `changed` runs once things have been quiet for a moment.
    func record(_ id: UUID, _ size: CGSize, changed: @escaping @MainActor () -> Void) {
        guard size.width > 1, size.height > 1 else { return }
        if let old = sizes[id], abs(old.width - size.width) < 0.5, abs(old.height - size.height) < 0.5 { return }
        sizes[id] = size
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            changed()
        }
    }
}
