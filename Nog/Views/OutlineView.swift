import SwiftUI

/// Folders-and-files view: top-level items, with projects expanding into their sub-items.
struct OutlineView: View {
    @Environment(ItemStore.self) private var store
    let showNogged: Bool
    /// "" = All, otherwise only this tag's items (and what's filed under them).
    var page: String = ""

    struct Node: Identifiable {
        let item: Item
        var children: [Node]?
        var id: UUID { item.id }
    }

    @Environment(Router.self) private var router
    /// Collapsed folder ids, remembered between launches.
    @AppStorage("outlineCollapsed") private var collapsedRaw = ""
    static let unfiledID = UUID(uuidString: "00000000-0000-0000-0000-00000000F11E")!

    var body: some View {
        let roots = Self.tree(MapPage.items(Array(store.items.values), page: page, showNogged: showNogged),
                              showNogged: showNogged)
        let folders = roots.filter { $0.children != nil }
        let unfiled = roots.filter { $0.children == nil }

        List {
            // Every node with things connected under it on the map is a folder.
            ForEach(folders) { folder in
                Section(isExpanded: expanded(folder.id)) {
                    ForEach(folder.children ?? []) { child in
                        OutlineBranch(node: child, expanded: expanded)
                    }
                } header: {
                    FolderHeader(item: folder.item, count: Self.count(folder)) { router.push(folder.item.id) }
                }
            }
            if !unfiled.isEmpty {
                Section(isExpanded: expanded(Self.unfiledID)) {
                    ForEach(unfiled) { node in
                        OutlineBranch(node: node, expanded: expanded)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Image(systemName: "tray").foregroundStyle(Theme.muted)
                        Text("UNFILED").font(.nogLabel).tracking(2).foregroundStyle(Theme.muted)
                        Text(String(format: "%02d", unfiled.count)).font(.nogMeta).foregroundStyle(Theme.muted.opacity(0.7))
                    }
                }
            }
        }
        .listStyle(.sidebar) // makes section headers collapsible
        .nogListStyle()
        .overlay {
            if roots.isEmpty {
                ContentUnavailableView("No items yet", systemImage: "folder",
                                       description: Text("On the map, select a node, then hold it over another to file it there."))
            }
        }
    }

    private var collapsed: Set<UUID> {
        Set(collapsedRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func expanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { isOpen in
                var set = collapsed
                if isOpen { set.remove(id) } else { set.insert(id) }
                collapsedRaw = set.map(\.uuidString).sorted().joined(separator: ",")
            })
    }

    /// Items inside a folder, at any depth.
    nonisolated static func count(_ node: Node) -> Int {
        (node.children ?? []).reduce(0) { $0 + 1 + count($1) }
    }

    nonisolated static func tree(_ items: [Item], showNogged: Bool) -> [Node] {
        let visible = items.filter { showNogged || $0.status != .done }
        let ids = Set(visible.map(\.id))
        var byParent: [UUID?: [Item]] = [:]
        for item in visible {
            let parent = item.parentID.flatMap { ids.contains($0) ? $0 : nil }
            byParent[parent, default: []].append(item)
        }
        func order(_ a: Item, _ b: Item) -> Bool {
            let rank: [ItemStatus: Int] = [.doing: 0, .open: 1, .someday: 2, .done: 3]
            if rank[a.status] != rank[b.status] { return rank[a.status]! < rank[b.status]! }
            return a.created < b.created
        }
        var visited = Set<UUID>()
        func build(_ parent: UUID?) -> [Node] {
            (byParent[parent] ?? []).sorted(by: order).compactMap { item in
                guard visited.insert(item.id).inserted else { return nil } // guards against cycles
                let children = build(item.id)
                return Node(item: item, children: children.isEmpty ? nil : children)
            }
        }
        var roots = build(nil)
        // Items stuck in a parent loop (A inside B inside A) still show up, at the top level.
        for item in visible.sorted(by: order) where !visited.contains(item.id) {
            visited.insert(item.id)
            let children = build(item.id)
            roots.append(Node(item: item, children: children.isEmpty ? nil : children))
        }
        return roots
    }
}

/// A row, or a collapsible sub-folder with its own rows.
private struct OutlineBranch: View {
    let node: OutlineView.Node
    let expanded: (UUID) -> Binding<Bool>

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: expanded(node.id)) {
                ForEach(children) { child in
                    AnyView(OutlineBranch(node: child, expanded: expanded))
                }
            } label: {
                NavigationLink(value: node.item.id) {
                    OutlineRow(item: node.item, childCount: OutlineView.count(node))
                }
            }
            .listRowBackground(Theme.glass)
        } else {
            NavigationLink(value: node.item.id) {
                OutlineRow(item: node.item, childCount: 0)
            }
            .listRowBackground(Theme.glass)
        }
    }
}

/// Section header for a top-level folder: tap the header to collapse, the arrow to open it.
private struct FolderHeader: View {
    @Environment(ItemStore.self) private var store
    let item: Item
    let count: Int
    let open: () -> Void

    var body: some View {
        let kids = store.children(of: item.id)
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.blue)
                .frame(width: 26, height: 26)
                .overlay {
                    if !kids.isEmpty {
                        ProgressRing(fraction: Double(kids.filter { $0.status == .done }.count) / Double(kids.count),
                                     lineWidth: 2)
                    }
                }
            Text(item.title.uppercased())
                .font(.nogLabel)
                .tracking(1.6)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(String(format: "%02d", count)).font(.nogMeta).foregroundStyle(Theme.muted)
            ForEach(item.tags.prefix(2), id: \.self) { tag in
                let pair = TagPalette.color(for: tag)
                Text("#\(tag)").font(.caption2.weight(.medium)).foregroundStyle(Color(light: pair.light, dark: pair.dark))
            }
            Spacer()
            Button(action: open) {
                Image(systemName: "arrow.up.right.circle").foregroundStyle(Theme.blue)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open \(item.title)")
        }
        .textCase(nil)
    }
}

private struct OutlineRow: View {
    let item: Item
    let childCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: childCount > 0 ? "folder" : icon)
                .foregroundStyle(childCount > 0 ? Theme.blue : tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .strikethrough(item.status == .done)
                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                if childCount > 0 || !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        if childCount > 0 {
                            Text("\(childCount) ITEMS").font(.nogMeta).foregroundStyle(Theme.muted)
                        }
                        ForEach(item.tags.prefix(3), id: \.self) { tag in
                            let pair = TagPalette.color(for: tag)
                            Text("#\(tag)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color(light: pair.light, dark: pair.dark))
                        }
                    }
                }
            }
        }
    }

    private var icon: String {
        switch item.status {
        case .done: "checkmark.circle"
        case .doing: "play.circle"
        case .someday: "moon.stars"
        case .open: item.reminder == nil ? "doc.text" : "bell"
        }
    }

    private var tint: Color {
        switch item.status {
        case .done, .doing: Theme.blue
        case .someday: Theme.violet
        case .open: item.reminder == nil ? Theme.muted : Theme.pink
        }
    }
}
