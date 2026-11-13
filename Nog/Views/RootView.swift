import AppIntents
import SwiftUI

/// The List tab (carton icon): a sortable Table, a week-planner Agenda, or an Outline you
/// drill into one level at a time. All three share one toolbar (Select, Sort, Settings),
/// one row (NogRow), one set of swipes and one Select mode. Search is its own tab.
struct NogsTab: View {
    @Environment(Router.self) private var router
    @Environment(ItemStore.self) private var store
    /// Which view of the list, remembered between launches.
    @AppStorage(ListMode.key) private var mode: ListMode = .table
    /// Select mode: tap rows to pick several, then act on them from the bottom bar.
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<UUID> = []
    /// Which way the Outline slides: in (from the right) or back out (from the left).
    @State private var outlineForward = true
    /// How far a swipe from the left edge has pulled the Overview page (to go back).
    @State private var edgeDrag: CGFloat = 0
    /// How far through that swipe it is, 0 to 1.
    @State private var backProgress: CGFloat = 0

    private var isSelecting: Bool { editMode.isEditing }

    /// What "Select All" picks: everything listed except the finished pile.
    private var selectable: Set<UUID> {
        Set(store.items.values.filter { $0.status != .done }.map(\.id))
    }

    /// The Outline's place, minus any nog that has since been deleted.
    private var trail: [UUID] {
        Array(router.outlineTrail.prefix { $0 == OverviewPage.looseID || store.items[$0] != nil })
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            // Re-render each minute and as nogs start, so "in 5 min" / "nogging now" stay current.
            TimelineView(MinuteSchedule.forItems(store.items.values)) { context in
                content(now: context.date)
            }
            .background { NogBackground() }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    SilenceBanner()
                    VStack(spacing: 0) {
                        if !isSelecting {
                            Picker("View", selection: $mode) {
                                ForEach(ListMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)
                        }
                        if mode == .overview && !trail.isEmpty {
                            // Swiping back to the top level, the bar fades and folds away
                            // with your finger, so the page doesn't jump up at the end.
                            OutlinePathBar(trail: trail) { go(to: $0) }
                                .padding(.top, isSelecting ? 0 : 8)
                                .collapsing(trail.count == 1 ? backProgress : 0)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .nogTabTitle(.nogs, title: isSelecting ? (selection.isEmpty ? "Select nogs" : "\(selection.count) selected") : nil)
            .environment(\.editMode, $editMode)
            .environment(\.openSteps, OpenStepsAction { id in showSteps(id) })
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        let all = selectable
                        Button(selection.isSuperset(of: all) && !all.isEmpty ? "Deselect All" : "Select All") {
                            selection = selection.isSuperset(of: all) ? [] : all
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { stopSelecting() }
                            .fontWeight(.semibold)
                    }
                } else {
                    // The same three in every view, sharing one glass capsule.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Select") {
                            withNogAnimation(.snappy) { editMode = .active }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { ListSortMenu() }
                    // Last, so it's always the top-right corner, as on every tab.
                    SettingsToolbarItem()
                }
            }
            // The tab bar makes way for the action bar while selecting, as in Mail and Photos.
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    BulkActionBar(selection: $selection)
                        .padding(.horizontal, 18)
                        .frame(height: 64)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.nog(.move(edge: .bottom).combined(with: .opacity)))
                }
            }
            .nogFeedback(.selection, trigger: selection.count)
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch mode {
        case .table:
            NogTable(now: now, selection: $selection)
        case .agenda:
            AgendaList(now: now, selection: $selection)
        case .overview:
            // Each level is its own page, so going in or out slides like an iPod menu
            // (a fade with Reduce Motion or Low stimulation).
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let progress = min(edgeDrag / width, 1)
                ZStack(alignment: .leading) {
                    // While a back swipe is under way, the level you're going back to waits
                    // underneath, sliding in from a little to the left as it fades up.
                    if edgeDrag > 0 {
                        OutlineBrowser(now: now, selection: $selection, trail: Array(trail.dropLast()),
                                       open: { _ in }, back: {})
                        .id(trail.dropLast().last)
                        .offset(x: (progress - 1) * width * 0.3)
                        .opacity(progress)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    OutlineBrowser(now: now, selection: $selection, trail: trail,
                                   open: { go(to: $0) }, back: { go(to: Array(trail.dropLast())) })
                    .id(trail.last)
                    .transition(.nog(.push(from: outlineForward ? .trailing : .leading)))
                    .offset(x: edgeDrag)
                    .opacity(1 - progress)
                    if !trail.isEmpty && !isSelecting {
                        backSwipeEdge(width: width)
                    }
                }
            }
        }
    }

    /// Swipe right from the left edge to go back a level, as on any iOS page. A thin strip
    /// along the edge takes the swipe, so rows' own swipe actions (which start further in)
    /// don't fire too. The page follows your finger, with the level above showing through.
    private func backSwipeEdge(width: CGFloat) -> some View {
        Color.clear
            .frame(width: 22)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        edgeDrag = min(max(0, value.translation.width), width)
                        backProgress = edgeDrag / width
                    }
                    .onEnded { value in
                        if value.translation.width > 90 || value.predictedEndTranslation.width > 200 {
                            finishBackSwipe(width: width)
                        } else {
                            withNogAnimation(.snappy) { edgeDrag = 0; backProgress = 0 }
                        }
                    }
            )
            // VoiceOver goes back with the path bar or the two-finger scrub.
            .accessibilityHidden(true)
    }

    /// Carries a back swipe through: the page slides the rest of the way off, then the level
    /// underneath takes its place without a second slide.
    private func finishBackSwipe(width: CGFloat) {
        let newTrail = Array(trail.dropLast())
        withNogAnimation(.snappy) {
            edgeDrag = width
            backProgress = 1
        } completion: {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                outlineForward = false
                selection = []
                router.outlineTrail = newTrail
                edgeDrag = 0
                backProgress = 0
            }
        }
    }

    /// Moves the Outline to `newTrail`, sliding in when it's deeper and out when it's shallower.
    private func go(to newTrail: [UUID]) {
        // Set the direction first, so the page leaving slides the right way too.
        outlineForward = newTrail.count >= trail.count
        selection = []
        DispatchQueue.main.async {
            withNogAnimation(.snappy) { router.outlineTrail = newTrail }
        }
    }

    /// A steps button ("4 ›") in any view: open the Outline inside that nog.
    private func showSteps(_ id: UUID) {
        let chain = store.chain(to: id)
        if mode != .overview {
            outlineForward = true
            router.outlineTrail = chain
            withNogAnimation(.snappy) { mode = .overview }
        } else {
            go(to: chain)
        }
    }

    private func stopSelecting() {
        withNogAnimation(.snappy) {
            editMode = .inactive
            selection = []
        }
    }
}

/// A faint lavender haze behind Dream nogs.
struct DreamHaze: View {
    var body: some View {
        ZStack {
            Theme.glass
            LinearGradient(colors: [Theme.violet.opacity(0.14), Theme.pink.opacity(0.05), Theme.violet.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Folds a view away from the bottom as `progress` goes from 0 to 1, fading it as it goes,
/// so whatever sits below rises with it smoothly rather than jumping when it's removed.
private struct Collapsing: ViewModifier {
    let progress: CGFloat
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(height: height.map { $0 * (1 - progress) }, alignment: .top)
            .opacity(1 - progress)
            .clipped()
    }
}

private extension View {
    func collapsing(_ progress: CGFloat) -> some View {
        modifier(Collapsing(progress: min(max(progress, 0), 1)))
    }
}
