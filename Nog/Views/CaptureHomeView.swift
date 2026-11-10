import AppIntents
import SwiftUI

/// The New Nog tab: one text box for the thought, sub-nogs as lines under it, and a
/// tray of options riding on the keyboard (when, Note/Nog/Alarm, tags, sub-nogs,
/// parent). Typed text still works ("tomorrow 9am #home"); the tray shows what it
/// understood, and anything picked there wins.
struct CaptureHomeView: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @State private var draft = CaptureDraft()
    @State private var panel: TrayPanel?
    @State private var showSubItems = false
    @State private var newSubItem = ""
    @State private var newTag = ""
    @State private var showKindHelp = false
    @State private var showHowTo = false
    @State private var showParentPicker = false
    @State private var confirmation: (text: String, id: UUID)?
    /// Apple's Siri tip ("Say 'Take a Nog'"); hidden for good once dismissed.
    @AppStorage("siriTip.capture") private var showSiriTip = true
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, subItem, tag }
    enum TrayPanel: Hashable {
        case when, kind, tags

        var title: String {
            switch self {
            case .when: "When"
            case .kind: "How it gets you"
            case .tags: "Tags"
            }
        }
    }

    private var defaults: CaptureDefaults { NogSettings.captureDefaults }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.capturePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    composer
                    if showSubItems || !draft.subItems.isEmpty { subItemList }
                    saveButton
                    readout
                    if draft.isEmpty && focus == nil {
                        hint
                        SiriTipView(intent: CaptureIntent(), isVisible: $showSiriTip)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { NogBackground() }
            // Tapping anywhere above the tray closes an open panel, as you'd expect.
            // VoiceOver users get Done and the escape gesture on the panel instead.
            .overlay {
                if panel != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closePanel)
                        .accessibilityHidden(true)
                }
            }
            .safeAreaInset(edge: .top) { SilenceBanner() }
            .nogTabTitle(.capture)
            .toolbar { SettingsToolbarItem() }
            // The tray sits on the keyboard while typing, and above the tab bar otherwise.
            .safeAreaInset(edge: .bottom) { tray }
            .navigationDestination(for: UUID.self) { id in
                ItemDetailView(id: id)
            }
            .sheet(isPresented: $showKindHelp) { NogKindSheet() }
            .sheet(isPresented: $showHowTo) { HowToNogSheet() }
            .sheet(isPresented: $showParentPicker) { CaptureParentPicker(selection: $draft.parentID) }
            // The keyboard opens only when you tap the box (or ask for Quick Capture).
            .onChange(of: router.captureFocusRequest) { focus = .title }
            .nogFeedback(.success, trigger: confirmation?.id)
        }
    }

    // MARK: Composer

    private var composer: some View {
        TextField("What's on your mind?", text: $draft.text, axis: .vertical)
            .font(.title3)
            .lineLimit(1...6)
            .focused($focus, equals: .title)
            .submitLabel(.send)
            .padding(16)
            .nogPanel(cornerRadius: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(focus == .title ? Theme.violet.opacity(0.55) : .clear, lineWidth: 1)
            }
            // Tab on a keyboard finishes a `!` word (`!unh` → `!unhinged`).
            .onKeyPress(.tab) {
                guard let first = completions.first else { return .ignored }
                draft.text = CaptureCompletion.complete(draft.text, with: first)
                return .handled
            }
            .onChange(of: draft.text) {
                // Return sends (a multi-line field otherwise inserts a newline).
                if draft.text.hasSuffix("\n") {
                    draft.text.removeLast()
                    submit()
                }
            }
    }

    /// Saves the nog, right under what you typed (Return on the keyboard does the same).
    private var saveButton: some View {
        Button(action: submit) {
            Text("SAVE")
        }
        .buttonStyle(GradientOutlineButtonStyle())
        .disabled(draft.isEmpty)
        .opacity(draft.isEmpty ? 0.45 : 1)
        .accessibilityLabel("Save")
        .accessibilityHint(draft.isEmpty ? "Type something first." : "Saves this nog.")
    }

    /// Sub-nogs typed straight in. Each one has its own line with a remove button, and the
    /// last line is always ready for the next: tap Add (or press Return) and keep going.
    /// They nog like this one.
    private var subItemList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: subNogCount > 1 ? "Sub-nogs" : "Sub-nog")
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(draft.subItems.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 12) {
                        Circle().strokeBorder(Theme.muted, lineWidth: 1.5).frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        Text(line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        removeButton(label: "Remove sub-nog \(line)") {
                            withNogAnimation { _ = draft.subItems.remove(at: index) }
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .frame(minHeight: 44)
                    Divider().overlay(Theme.edge)
                }
                HStack(spacing: 12) {
                    Image(systemName: "plus").foregroundStyle(Theme.muted).frame(width: 18)
                        .accessibilityHidden(true)
                    TextField(draft.subItems.isEmpty ? "Add a sub-nog" : "Add another sub-nog",
                              text: $newSubItem, axis: .vertical)
                        .focused($focus, equals: .subItem)
                        .submitLabel(.next)
                        .onChange(of: newSubItem) { addSubItemsOnReturn() }
                    if !pendingSubItem.isEmpty {
                        Button(action: commitPendingSubItem) {
                            Text("Add")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.blue)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .overlay(Capsule().strokeBorder(Theme.blue.opacity(0.7), lineWidth: 1))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add sub-nog \(pendingSubItem)")
                        .accessibilityHint("Keeps the box ready for another")
                    }
                    // Clears what's typed; with nothing else here it closes the section too.
                    if !pendingSubItem.isEmpty || draft.subItems.isEmpty {
                        removeButton(label: pendingSubItem.isEmpty ? "Remove sub-nog" : "Clear \(pendingSubItem)") {
                            newSubItem = ""
                            if draft.subItems.isEmpty {
                                withNogAnimation { showSubItems = false }
                                focus = .title
                            }
                        }
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .frame(minHeight: 44)
            }
            .nogPanel(cornerRadius: 14)
        }
    }

    /// A 44-point ✕ that removes one sub-nog.
    private func removeButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.body)
                .foregroundStyle(Theme.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// What's typed in the add box, trimmed.
    private var pendingSubItem: String { newSubItem.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Sub-nogs on the page, counting one still being typed.
    private var subNogCount: Int { draft.subItems.count + (pendingSubItem.isEmpty ? 0 : 1) }

    /// The Add button: keeps what's typed and leaves the cursor ready for the next one.
    private func commitPendingSubItem() {
        let line = pendingSubItem
        guard !line.isEmpty else { return }
        withNogAnimation { draft.subItems.append(line) }
        newSubItem = ""
        focus = .subItem
    }

    /// Return adds the line and keeps the cursor here; Return on an empty line goes back to the title.
    private func addSubItemsOnReturn() {
        guard newSubItem.contains("\n") else { return }
        let lines = newSubItem.split(separator: "\n", omittingEmptySubsequences: false)
        let finished = lines.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let rest = String(lines.last ?? "")
        if finished.isEmpty && rest.trimmingCharacters(in: .whitespaces).isEmpty {
            newSubItem = ""
            focus = .title
            return
        }
        draft.subItems.append(contentsOf: finished)
        newSubItem = rest
        focus = .subItem
    }

    /// Live read-back of what will be saved, or the last capture's confirmation.
    @ViewBuilder
    private var readout: some View {
        if !draft.isEmpty {
            let result = draft.resolved(defaults: defaults, now: .now)
            Text("→ " + Self.summary(result, subItems: draft.subItems.count,
                                     parent: draft.parentID.flatMap { store.items[$0]?.title }).uppercased())
                .font(.nogMeta)
                .tracking(0.4)
                .foregroundStyle(Theme.blue)
                .padding(.horizontal, 6)
        } else if let confirmation {
            Button {
                router.push(confirmation.id)
            } label: {
                Text(confirmation.text + "  ›")
                    .font(.nogMeta)
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .transition(.opacity)
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Type anything, like \"call mom tomorrow 9am #family !2h\". Dates, #tags and !shortcuts work anywhere in the line, or use the tray below.")
                .font(.callout)
                .foregroundStyle(Theme.muted)
            Button { showHowTo = true } label: {
                Label("How to Nog", systemImage: "questionmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.violet)
            }
            .accessibilityHint("Shows everything you can type")
        }
    }

    static func summary(_ result: CaptureResult, subItems: Int, parent: String?) -> String {
        var parts = [result.title.isEmpty ? "Untitled" : result.title]
        if let r = result.reminder {
            parts.append(Self.whenText(r.start, now: .now))
            if let rec = result.recurrence { parts.append("repeats \(rec.summary)") }
            parts.append(r.alarm ? "alarm" : "nog")
            if let every = r.repeatSummary { parts.append(every) }
        } else {
            parts.append("note, never nogs")
        }
        if !result.tags.isEmpty { parts.append(result.tags.map { "#\($0)" }.joined(separator: " ")) }
        if subItems > 0 { parts.append("\(subItems) sub-nog\(subItems == 1 ? "" : "s")") }
        if let parent { parts.append("in \(parent)") }
        return parts.joined(separator: " · ")
    }

    /// "In 15 min", "6:00 PM", "Tomorrow 9:00 AM", "Tue 9:00 AM".
    static func whenText(_ date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "In \(minutes) min" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    // MARK: Saving

    private func submit() {
        guard !draft.isEmpty else { return }
        let now = Date.now
        let result = draft.resolved(defaults: defaults, now: now)
        let own = draft.choseOwnRhythm(defaults: defaults, now: now)
        let pending = newSubItem.trimmingCharacters(in: .whitespacesAndNewlines)
        let subItems = draft.subItems + (pending.isEmpty ? [] : [pending])
        var created: Item?
        store.batch {
            created = store.add(result, parent: draft.parentID, ownRhythm: own, now: now)
            if let parent = created {
                for line in subItems { store.capture(line, parent: parent.id, now: now) }
            }
        }
        guard let item = created else { return }
        draft = CaptureDraft()
        newSubItem = ""
        showSubItems = false
        panel = nil
        focus = .title // keep the keyboard up for the next thought
        withNogAnimation {
            confirmation = ("✓ Caught · " + Self.summary(result, subItems: subItems.count, parent: nil).uppercased(), item.id)
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withNogAnimation { if confirmation?.id == item.id { confirmation = nil } }
        }
    }

    // MARK: Tray

    private var tray: some View {
        let result = draft.resolved(defaults: defaults, now: .now)
        let kind = draft.kind ?? NogKind.of(result.reminder)
        return VStack(spacing: 8) {
            if focus == .title, !completions.isEmpty {
                completionRow
            }
            if let panel {
                TrayPanelCard(title: panel.title, close: closePanel) {
                    panelView(panel, result: result, kind: kind)
                }
                .padding(.horizontal, 10)
                .transition(.nog(.move(edge: .bottom).combined(with: .opacity)))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(result.reminder.map { Self.whenText($0.start, now: .now) } ?? "No time",
                         systemImage: "calendar", tint: Theme.blue,
                         isOn: draft.when != nil, isOpen: panel == .when) { toggle(.when) }
                    chip(kind.label, systemImage: kind.systemImage, tint: kind.tint,
                         isOn: kind != .note, isOpen: panel == .kind) { toggle(.kind) }
                    chip(result.tags.isEmpty ? "Tags" : result.tags.map { "#\($0)" }.joined(separator: " "),
                         systemImage: "number", tint: Theme.violet,
                         isOn: !result.tags.isEmpty, isOpen: panel == .tags) { toggle(.tags) }
                    chip(draft.subItems.isEmpty ? "Sub-nogs" : "\(draft.subItems.count) sub-nogs",
                         systemImage: "list.bullet", tint: Theme.blue,
                         isOn: !draft.subItems.isEmpty, isOpen: false) {
                        panel = nil
                        showSubItems = true
                        focus = .subItem
                    }
                    chip(draft.parentID.flatMap { store.items[$0]?.title } ?? "Link",
                         systemImage: "link", tint: Theme.violet,
                         isOn: draft.parentID != nil, isOpen: false) { showParentPicker = true }
                        .accessibilityLabel(draft.parentID.flatMap { store.items[$0]?.title }.map { "Linked to \($0)" } ?? "Link")
                        .accessibilityHint("Puts this nog inside another one")
                    if focus != nil {
                        Button {
                            focus = nil
                            panel = nil
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .frame(width: 40, height: 36)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Hide keyboard")
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
        .nogAnimation(.snappy, value: panel)
    }

    /// `!` words matching what's being typed, offered above the tray.
    private var completions: [String] { CaptureCompletion.suggestions(for: draft.text) }

    private var completionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(completions, id: \.self) { token in
                    smallChip(token, isOn: false) {
                        draft.text = CaptureCompletion.complete(draft.text, with: token)
                    }
                    .accessibilityHint("Finishes the word")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background(.bar)
        .transition(.opacity)
    }

    private func toggle(_ p: TrayPanel) {
        if panel == p { closePanel(); return }
        panel = p
        if p == .tags { focus = .tag }
    }

    /// Close whichever panel is open. The tag field's keyboard goes with it;
    /// the title keeps its keyboard so you can carry on typing.
    private func closePanel() {
        if focus == .tag { focus = nil }
        newTag = ""
        panel = nil
    }

    private func chip(_ title: String, systemImage: String, tint: Color, isOn: Bool, isOpen: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(isOn || isOpen ? tint : Color.primary.opacity(0.8))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(isOpen ? tint.opacity(0.18) : (isOn ? tint.opacity(0.10) : .clear), in: Capsule())
                .overlay(Capsule().strokeBorder(isOn || isOpen ? tint.opacity(0.7) : Theme.edgeStrong,
                                                lineWidth: isOpen ? 1.5 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    @ViewBuilder
    private func panelView(_ p: TrayPanel, result: CaptureResult, kind: NogKind) -> some View {
        switch p {
        case .when: whenPanel(result)
        case .kind: kindPanel(result, kind: kind)
        case .tags: tagsPanel(result)
        }
    }

    // MARK: Panels

    private func whenPanel(_ result: CaptureResult) -> some View {
        let now = Date.now
        let calendar = Calendar.current
        var choices: [(String, Date)] = [
            ("In 15 min", now.addingTimeInterval(15 * 60)),
            ("In 1 hour", now.addingTimeInterval(3600)),
        ]
        if let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now), tonight > now {
            choices.append(("Tonight", tonight))
        }
        let morning = NogSettings.nextMorning(after: now)
        choices.append((calendar.isDateInToday(morning) ? "This morning" : "Tomorrow morning", morning))
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(choices, id: \.0) { label, date in
                    smallChip(label, isOn: draft.when.map { abs($0.timeIntervalSince(date)) < 90 } ?? false) {
                        setWhen(date)
                    }
                }
                if draft.when != nil {
                    smallChip("From text", isOn: false) { draft.when = nil }
                }
            }
            DatePicker("Pick", selection: Binding(
                get: { result.reminder?.start ?? now.addingTimeInterval(15 * 60) },
                set: { setWhen($0) }),
                in: now..., displayedComponents: [.date, .hourAndMinute])
                .font(.subheadline)
        }
    }

    /// Picking a time means you want reminding, so a Note becomes a Nog.
    private func setWhen(_ date: Date) {
        draft.when = date
        if draft.kind == .note { draft.kind = .nog }
    }

    private func kindPanel(_ result: CaptureResult, kind: NogKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            KindPicker(selected: kind) { picked in
                draft.kind = picked
                // Alarms need permission to ring; ask now, not when it's due.
                if picked == .alarm { Task { _ = await AlarmScheduler.shared.requestAuthorization() } }
            }
            Text(NogKind.promise(for: result.reminder))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let r = result.reminder {
                let current = draft.profile ?? NogProfile.matching(r)
                // Eight profiles: wrap onto more lines rather than squeeze.
                FlowLayout(spacing: 6) {
                    ForEach(NogProfile.allCases) { profile in
                        smallChip(profile.label, isOn: profile == current) { draft.profile = profile }
                    }
                }
            }
            Button("What's the difference?") { showKindHelp = true }
                .font(.subheadline)
                .buttonStyle(.borderless)
                .tint(Theme.violet)
        }
    }

    private func tagsPanel(_ result: CaptureResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(result.tags, id: \.self) { tag in
                    let added = draft.extraTags.contains(tag)
                    Button {
                        if added { draft.extraTags.removeAll { $0 == tag } }
                    } label: {
                        Text(added ? "#\(tag) ✕" : "#\(tag)")
                            .font(.subheadline)
                            .foregroundStyle(TagPalette.tint(for: tag))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .overlay(Capsule().strokeBorder(TagPalette.tint(for: tag).opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!added)
                    .accessibilityLabel(added ? "Remove tag \(tag)" : "Tag \(tag), typed in the text")
                }
                TextField("add tag", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .tag)
                    .submitLabel(.done)
                    .onSubmit { addTag(newTag) }
                    .frame(width: 120).frame(minHeight: 30)
                    .padding(.horizontal, 10)
                    .overlay(Capsule().strokeBorder(Theme.edgeStrong, lineWidth: 1))
            }
            TagSuggestionStrip(title: newTag.isEmpty ? "Recent" : "Tags",
                               tags: TagSuggester.suggest(newTag, from: TagSuggester.stats(store.items.values),
                                                          excluding: Set(result.tags))) { addTag($0) }
        }
    }

    private func addTag(_ raw: String) {
        let tag = Item.cleanTag(raw)
        newTag = ""
        guard !tag.isEmpty, !draft.extraTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        draft.extraTags.append(tag)
    }

    private func smallChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(isOn ? Theme.blue : Color.primary.opacity(0.85))
                .padding(.horizontal, 11)
                .frame(minHeight: 32)
                .background(isOn ? Theme.blue.opacity(0.14) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn ? Theme.blue : Theme.edgeStrong, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The card an open tray panel sits in, with three ways out: the Done button
/// (Escape on a hardware keyboard), a swipe down on its top edge, and the
/// VoiceOver escape gesture (two-finger scrub). Tapping outside is handled by
/// the New Nog screen.
private struct TrayPanelCard<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    @GestureState private var dragDown: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .offset(y: dragDown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) options")
        .accessibilityAction(.escape, close)
    }

    /// Grabber, title and Done. The swipe lives here only, so it never fights
    /// the date picker or the sideways-scrolling tag suggestions below.
    private var header: some View {
        VStack(spacing: 2) {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)
            HStack {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: close)
                    .font(.body.weight(.semibold))
                    .tint(Theme.violet)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes the \(title.lowercased()) options")
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .updating($dragDown) { value, state, _ in state = max(0, value.translation.height) }
                .onEnded { value in
                    if value.translation.height > 50 || value.predictedEndTranslation.height > 120 { close() }
                }
        )
    }
}

/// Pick the item a new capture goes inside.
private struct CaptureParentPicker: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: UUID?
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if selection != nil {
                    Button("Don't link") {
                        selection = nil
                        dismiss()
                    }
                }
                let query = search.lowercased()
                let candidates = store.items.values
                    .filter { $0.status != .done }
                    .filter { query.isEmpty || $0.title.lowercased().contains(query) }
                    .sorted { $0.updated > $1.updated }
                    .prefix(60)
                ForEach(Array(candidates)) { candidate in
                    Button {
                        selection = candidate.id
                        dismiss()
                    } label: {
                        HStack {
                            Text(candidate.title).foregroundStyle(.primary)
                            Spacer()
                            if candidate.id == selection { Image(systemName: "checkmark").foregroundStyle(Theme.blue) }
                        }
                    }
                }
            }
            .nogListStyle()
            .searchable(text: $search)
            .navigationTitle("Link to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// New Nog · Agenda · List · Map. Each tab has its own accent colour (see TabTheme.swift).
struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(ItemStore.self) private var store
    @AppStorage(OnboardingView.doneKey) private var onboardingDone = false
    /// First-run setup waits until we know this isn't an existing install.
    @State private var checkedFirstRun = false

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab(AppTab.capture.title, systemImage: "plus.circle", value: AppTab.capture) {
                CaptureHomeView().nogTabTheme(.capture)
            }
            Tab(AppTab.agenda.title, systemImage: "calendar", value: AppTab.agenda) {
                AgendaView().nogTabTheme(.agenda)
            }
            Tab(AppTab.nogs.title, image: "TabCarton", value: AppTab.nogs) {
                NogsTab().nogTabTheme(.nogs)
            }
            Tab(AppTab.map.title, systemImage: "point.3.connected.trianglepath.dotted", value: AppTab.map) {
                MapTab().nogTabTheme(.map)
            }
        }
        // The selected tab lights up in that tab's colour.
        .tint(router.tab.accent)
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $router.showSilenceSheet) { SilenceSheet() }
        .sheet(isPresented: $router.showSettings) { SettingsView() }
        // First run only: what Nog does, how firm, and permissions with their reasons.
        .fullScreenCover(isPresented: Binding(get: { checkedFirstRun && !onboardingDone },
                                              set: { if !$0 { onboardingDone = true } })) {
            OnboardingView()
        }
        .task {
            // Anyone who used Nog before first-run setup existed skips it.
            if !onboardingDone {
                await store.refresh()
                let status = await NotificationScheduler.shared.authorizationStatus()
                if !store.items.isEmpty || status != .notDetermined { onboardingDone = true }
            }
            checkedFirstRun = true
        }
    }
}
