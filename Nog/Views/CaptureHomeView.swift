import SwiftUI

/// The tab Nog opens to: one text box, and just enough below it to know your
/// capture landed and what's coming next. No timers, no long lists.
struct CaptureHomeView: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @State private var text = ""
    @State private var showSettings = false
    @State private var confirmation: String?
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.capturePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    composer
                    justCaught
                    nextNogs
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { NogBackground() }
            .navigationTitle("NOG")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { focused = true }
            .onChange(of: router.captureFocusRequest) { focused = true }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What's on your mind?", text: $text, axis: .vertical)
                .font(.title3)
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.send)
                .padding(16)
                .nogPanel(cornerRadius: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(focused ? Theme.violet.opacity(0.55) : .clear, lineWidth: 1)
                }
                .onChange(of: text) {
                    // Return sends (a multi-line field otherwise inserts a newline).
                    if text.hasSuffix("\n") {
                        text.removeLast()
                        submit()
                    }
                }

            HStack(alignment: .center) {
                if let preview {
                    Text("→ " + preview.uppercased())
                        .font(.nogMeta)
                        .tracking(0.4)
                        .foregroundStyle(Theme.blue)
                        .lineLimit(2)
                } else if let confirmation {
                    Text(confirmation)
                        .font(.nogMeta)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .transition(.opacity)
                }
                Spacer(minLength: 12)
                Button("NOG IT", action: submit)
                    .buttonStyle(GradientOutlineButtonStyle())
                    .frame(width: 128)
                    .disabled(isEmpty)
                    .opacity(isEmpty ? 0.45 : 1)
            }
        }
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var preview: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parsed = CaptureParser.parse(trimmed, defaults: NogSettings.captureDefaults, now: .now)
        guard !parsed.title.isEmpty else { return nil }
        return "\(parsed.title) · \(CaptureBar.describe(parsed.reminder))"
    }

    private func submit() {
        guard !isEmpty, let item = store.capture(text) else { return }
        text = ""
        focused = true
        withAnimation { confirmation = "✓ CAUGHT · \(CaptureBar.describe(item.reminder).uppercased())" }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { confirmation = nil }
        }
    }

    // MARK: Lists

    /// The three latest captures (shown once, under Just caught).
    private var recentItems: [Item] {
        Array(store.items.values.sorted { $0.created > $1.created }.prefix(3))
    }

    @ViewBuilder
    private var justCaught: some View {
        let recent = recentItems
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Just caught")
                VStack(spacing: 0) {
                    ForEach(recent) { item in
                        CompactRow(item: item, trailing: item.created.formatted(.relative(presentation: .named)))
                        if item.id != recent.last?.id { Divider().overlay(Theme.edge) }
                    }
                }
                .nogPanel()
            }
        } else {
            Text("Type anything: a to-do, an idea, \"lunch next tues\". Nog will keep reminding you until it's done.")
                .font(.callout)
                .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private var nextNogs: some View {
        let now = Date.now
        // Skip what's already listed under Just caught, so nothing shows twice.
        let shown = Set(recentItems.map(\.id))
        let upcoming = store.items.values
            .compactMap { item -> (Item, Date)? in
                guard item.isOpen, !shown.contains(item.id), let r = item.reminder else { return nil }
                return (item, r.isActive(at: now) ? now : r.start)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Next nogs")
                VStack(spacing: 0) {
                    ForEach(Array(upcoming), id: \.0.id) { item, when in
                        CompactRow(item: item, trailing: Self.whenLabel(when, now: now))
                        if item.id != upcoming.last?.0.id { Divider().overlay(Theme.edge) }
                    }
                }
                .nogPanel()
            }
        }
    }

    static func whenLabel(_ date: Date, now: Date) -> String {
        if date <= now.addingTimeInterval(30) { return "NOW" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()).uppercased()
    }
}

/// A single tappable line: status icon, title, and a mono readout on the right.
struct CompactRow: View {
    let item: Item
    let trailing: String

    var body: some View {
        NavigationLink(value: item.id) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                Text(item.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.nogMeta)
                    .foregroundStyle(trailing == "NOW" ? Theme.pink : Theme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch item.status {
        case .done: "checkmark.circle"
        case .doing: "play.circle"
        case .someday: "moon.stars"
        case .open: item.reminder == nil ? "lightbulb" : (item.reminder!.alarm ? "alarm" : "bell")
        }
    }

    private var tint: Color {
        switch item.status {
        case .done, .doing: Theme.blue
        case .someday: Theme.violet
        case .open: item.reminder.map { $0.isActive(at: .now) ? Theme.pink : Theme.violet } ?? Theme.muted
        }
    }
}

/// Capture · Nogs · Map
struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Capture", systemImage: "square.and.pencil", value: AppTab.capture) {
                CaptureHomeView()
            }
            Tab("Nogs", systemImage: "bell", value: AppTab.nogs) {
                NogsTab()
            }
            Tab("Map", systemImage: "point.3.connected.trianglepath.dotted", value: AppTab.map) {
                MapTab()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
