import AppIntents
import SwiftUI

struct ItemDetailView: View {
    @Environment(ItemStore.self) private var store
    let id: UUID
    /// Opens the recorder at once (a voice nog made from New Nog).
    var autoRecord = false
    /// Off inside a sheet that has its own Cancel and Save in the bar.
    var showsMenu = true

    var body: some View {
        if let item = store.items[id] {
            ItemEditor(item: item, autoRecord: autoRecord, showsMenu: showsMenu)
        } else {
            ContentUnavailableView("Item deleted", systemImage: "trash")
        }
    }
}

private struct ItemEditor: View {
    @Environment(ItemStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: Item
    var autoRecord = false
    var showsMenu = true

    @State private var newChild = ""
    @FocusState private var childFieldFocused: Bool
    @State private var newTag = ""
    @State private var isAddingTag = false
    @FocusState private var tagFieldFocused: Bool
    @FocusState private var notesFocused: Bool
    @State private var notesCommitted = 0
    /// Notes grow with the text up to this height, then scroll inside themselves,
    /// so the caret is never pushed under the keyboard.
    @ScaledMetric(relativeTo: .body) private var notesMaxHeight: CGFloat = 240
    @State private var showBreakdown = false
    @State private var showParentPicker = false
    @State private var showNogSheet = false
    @State private var showKnob = false
    @State private var confirmDelete = false

    /// Edits go straight to the store (and disk), so a "Done" tapped on a
    /// notification while this screen is open is never overwritten.
    private func binding<T>(_ keyPath: WritableKeyPath<Item, T>) -> Binding<T> {
        Binding(
            get: { store.items[item.id]?[keyPath: keyPath] ?? item[keyPath: keyPath] },
            set: { set(keyPath, $0) })
    }

    private func set<T>(_ keyPath: WritableKeyPath<Item, T>, _ value: T) {
        guard var current = store.items[item.id] else { return }
        current[keyPath: keyPath] = value
        store.update(current)
    }

    /// The knob behaves like the matching buttons: Doing starts with the suggested
    /// timebox, Nogged marks it done, Open stops or reopens, Dream parks it.
    private func setStatus(_ new: ItemStatus) {
        guard new != item.status else { return }
        switch new {
        case .doing: store.start(item.id)
        case .done: store.markDone(item.id)
        case .open: item.isDoing ? store.stopDoing(item.id) : store.reopen(item.id)
        case .someday: set(\.status, .someday)
        }
    }

    private var tint: Color { StatusDial.tint(item.status) }

    // The page, top to bottom: where it lives, what it is, its state and the one
    // thing to do next; then the content (notes, voice, sub-items, tags); details last.
    var body: some View {
        ScrollViewReader { proxy in
            Form {
                hero
                stateSection
                notesSection(proxy)
                childrenSection
                detailsSection
                linksSection
            }
            .scrollDismissesKeyboard(.interactively)
        }
        // Leaving the page stops this nog's voice note if one is playing.
        .onDisappear {
            if let playing = VoicePlayer.shared.playing, item.voiceNotes.contains(where: { $0.file == playing }) {
                VoicePlayer.shared.stop()
            }
        }
        .nogListStyle()
        .listSectionSpacing(14)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsMenu { ToolbarItem(placement: .topBarTrailing) { moreMenu } }
            // Notes are saved as you type; Done puts the keyboard away and confirms it.
            if notesFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { commitNotes() }
                        .fontWeight(.semibold)
                        .accessibilityHint("Saves the notes and hides the keyboard")
                }
            }
        }
        .nogFeedback(.success, trigger: notesCommitted)
        .sheet(isPresented: $showParentPicker) {
            ParentPicker(item: item)
        }
        .sheet(isPresented: $showBreakdown) {
            BreakdownSheet(item: item)
        }
        .sheet(isPresented: $showNogSheet) {
            NogSheet(id: item.id)
        }
        .nogFeedback(.success, trigger: item.status) { _, new in new == .done }
        .nogAnimation(.snappy, value: item.status)
        // iOS 27 on-screen awareness: "Siri, snooze this", "mark this done".
        .appEntityIdentifier(EntityIdentifier(for: ReminderEntity.self, identifier: item.id))
    }

    // MARK: Hero

    private var hero: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if let parent = store.parent(of: item) {
                    Button {
                        router.goUp(to: parent.id)
                    } label: {
                        Label(parent.title.uppercased(), systemImage: "arrow.up")
                            .font(.nogLabel)
                            .tracking(1.6)
                            .nogLineLimit()
                            .foregroundStyle(Theme.violet)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Part of \(parent.title)")
                }
                TextField("Title", text: binding(\.title), axis: .vertical)
                    .font(.nogTitle(28))
                    .foregroundStyle(item.status == .done ? Theme.muted : .primary)
                // Status, age and tags share one wrapping row under the title.
                FlowLayout(spacing: 8) {
                    statusPill
                    Text(metaLine)
                        .font(.nogMeta)
                        .foregroundStyle(Theme.muted)
                        .padding(.trailing, 2)
                    tagChips
                }
                tagSuggestions
            }
            .padding(.vertical, 2)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }

    /// The status, coloured by state. Tap to turn the knob.
    private var statusPill: some View {
        Button {
            showKnob = true
        } label: {
            HStack(spacing: 7) {
                if item.status == .done {
                    Image(systemName: "checkmark").nogFont(10, weight: .heavy)
                } else {
                    Circle().fill(tint).frame(width: 7, height: 7).nogGlow(color: tint, radius: 3)
                }
                Text(item.status.label.uppercased())
                    .font(.nogLabel)
                    .tracking(1.5)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Status: \(item.status.label)")
        .accessibilityHint("Opens the status knob")
        .popover(isPresented: $showKnob) {
            VStack(spacing: 4) {
                StatusDial(status: item.status) { new in
                    setStatus(new)
                }
                Text(StatusDial.summary(item.status))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding(16)
            .presentationCompactAdaptation(.popover)
        }
    }

    /// "~15 min · Tue"
    private var metaLine: String {
        var parts: [String] = []
        if let estimate = item.estimateMinutes { parts.append("~" + IntervalFormat.amount(estimate)) }
        parts.append(Self.dayWord(item.created).capitalized)
        return parts.joined(separator: " · ")
    }

    /// "today", "yesterday", "Tue", or "Nov 3".
    static func dayWord(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: State: next nog / doing / nogged, plus the two actions

    @ViewBuilder
    private var stateSection: some View {
        switch item.status {
        case .doing:
            Section {
                DoingCard(item: item, showsTitle: false)
                    .listRowBackground(Color.clear)
                    // A little room so the section's rounded clip doesn't cut the card.
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
        case .done:
            Section {
                NoggedCard(item: item) { store.reopen(item.id) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
        case .open, .someday:
            // Start and Done sit inside the timer panel, under the next nog.
            Section {
                if item.status == .someday {
                    DreamCard(reopen: { store.reopen(item.id) }) { actions }
                } else {
                    NextNogCard(item: item, edit: { showNogSheet = true }) { actions }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }

    /// ▶︎ Start and ✓ Done, side by side, at the foot of the timer panel. Finishing is its own clearly-labelled
    /// action, never a "save" button: edits on this page are saved as you make them.
    private var actions: some View {
        // Stacked at the accessibility text sizes, so neither button truncates.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            StartButton(item: item, prominent: true)
            Button {
                store.markDone(item.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").nogFont(12, weight: .bold)
                    Text("DONE").font(.nogTitle(13)).tracking(2)
                }
                .foregroundStyle(StatusDial.tint(.done))
                .padding(.vertical, 15)
                .frame(minWidth: 124, maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(StatusDial.tint(.done).opacity(0.75), lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Mark done")
        }
    }

    // MARK: Content

    private static let notesAnchor = "notes"

    private func commitNotes() {
        notesFocused = false
        notesCommitted += 1
        AccessibilityNotification.Announcement("Notes saved").post()
    }

    private func notesSection(_ proxy: ScrollViewProxy) -> some View {
        Section {
            TextEditor(text: binding(\.body))
                .focused($notesFocused)
                .frame(minHeight: 120, maxHeight: notesMaxHeight)
                .scrollContentBackground(.hidden)
                // As the notes grow a line, keep their bottom edge (and so the caret)
                // above the keyboard instead of letting it slide underneath.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                    guard notesFocused else { return }
                    withAnimation(.snappy) { proxy.scrollTo(Self.notesAnchor, anchor: .bottom) }
                }
                .onChange(of: notesFocused) { _, focused in
                    guard focused else { return }
                    withAnimation(.snappy) { proxy.scrollTo(Self.notesAnchor, anchor: .bottom) }
                }
                .id(Self.notesAnchor)
                .overlay(alignment: .topLeading) {
                    if item.body.isEmpty {
                        Text(verbatim: "[[Title]] links a nog.")
                            .italic()
                            .foregroundStyle(Theme.muted.opacity(0.6))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(item.status == .done ? Theme.muted : .primary)
                .accessibilityLabel("Notes")
            // Spoken notes live with the typed ones.
            VoiceNoteRows(item: item, autoRecord: autoRecord)
        } header: {
            SectionLabel(title: "Notes")
        }
        .listRowBackground(Theme.glass)
    }

    private var childrenSection: some View {
        let children = store.children(of: item.id)
        let done = children.filter { $0.status == .done }.count
        return Section {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                HStack {
                    Button {
                        if child.status == .done { store.reopen(child.id) } else { store.markDone(child.id) }
                    } label: {
                        Image(systemName: child.status == .done ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(child.status == .done ? Theme.blue : Theme.muted)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(child.status == .done ? "Reopen \(child.title)" : "Mark \(child.title) done")
                    NavigationLink(value: child.id) {
                        Text(child.title)
                            .strikethrough(child.status == .done)
                            .foregroundStyle(child.status == .done ? Theme.muted : .primary)
                    }
                    // Dragging needs a steady long press; these do the same in one step.
                    .accessibilityActions {
                        if index > 0 {
                            Button("Move up") { moveChild(child, by: -1) }
                        }
                        if index < children.count - 1 {
                            Button("Move down") { moveChild(child, by: 1) }
                        }
                    }
                }
            }
            // Touch and hold a sub-nog, then drag it to a new place. The order is saved.
            .onMove { source, destination in
                store.moveChildren(of: item.id, from: source, to: destination)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus").foregroundStyle(Theme.muted)
                // Multi-line field: Return arrives as a newline, which we turn into "add this one
                // and keep typing". A single-line field would end editing and drop the keyboard.
                TextField("Add sub-nog", text: $newChild, axis: .vertical)
                    .focused($childFieldFocused)
                    .submitLabel(.next)
                    .onChange(of: newChild) { addChildrenOnReturn() }
                    .nogFeedback(.impact(weight: .light), trigger: children.count)
                if ItemAssistant.isAvailable {
                    Button {
                        showBreakdown = true
                    } label: {
                        Label("Break down", systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(Theme.violet)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .overlay(Capsule().strokeBorder(Theme.violet.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            HStack {
                SectionLabel(title: children.isEmpty ? "Sub-nogs" : "Sub-nogs · \(done) of \(children.count)")
                if !children.isEmpty {
                    ProgressView(value: Double(done), total: Double(children.count))
                        .tint(Theme.blue)
                        .frame(width: 70)
                }
            }
        }
        .listRowBackground(Theme.glass)
    }

    private func moveChild(_ child: Item, by offset: Int) {
        let moved = withNogAnimation { store.moveChild(child.id, by: offset) }
        if let moved {
            AccessibilityNotification.Announcement("\(child.title) moved to \(moved.place) of \(moved.of)").post()
        }
    }

    /// Return adds what's typed as a sub-item and leaves the cursor ready for the next.
    /// Return on an empty line puts the keyboard away. Pasted lines become one sub-item each.
    private func addChildrenOnReturn() {
        guard newChild.contains("\n") else { return }
        let lines = newChild.split(separator: "\n", omittingEmptySubsequences: false)
        let finished = lines.dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let rest = String(lines.last ?? "")
        if finished.isEmpty && rest.trimmingCharacters(in: .whitespaces).isEmpty {
            newChild = ""
            childFieldFocused = false
            return
        }
        for line in finished { store.capture(line, parent: item.id) }
        newChild = rest
        childFieldFocused = true
    }

    /// The tag chips and "+ tag", laid out in the hero's status row.
    @ViewBuilder
    private var tagChips: some View {
        ForEach(item.tags, id: \.self) { tag in
            TagChip(tag: tag) { removeTag(tag) }
        }
        if isAddingTag {
            TextField("tag", text: $newTag)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($tagFieldFocused)
                .submitLabel(.done)
                .onSubmit(addTag)
                .frame(width: 110).frame(minHeight: 32)
                .padding(.horizontal, 12)
                .overlay(Capsule().strokeBorder(Theme.edgeStrong, lineWidth: 1))
                .onAppear { tagFieldFocused = true }
                // Tapped away with nothing typed: put the field away. With text, keep it
                // (and its suggestions) so a tap on a suggestion still lands.
                .onChange(of: tagFieldFocused) { _, focused in
                    if !focused, newTag.trimmingCharacters(in: .whitespaces).isEmpty {
                        withNogAnimation(.snappy) { isAddingTag = false }
                    }
                }
        } else {
            Button {
                withNogAnimation(.snappy) { isAddingTag = true }
            } label: {
                Text("+ tag")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .overlay(Capsule().strokeBorder(Theme.edgeStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add tag")
        }
    }

    /// While adding a tag: recent or matching tags to tap.
    @ViewBuilder
    private var tagSuggestions: some View {
        if isAddingTag {
            let suggestions = TagSuggester.suggest(newTag, from: TagSuggester.stats(store.items.values),
                                                   excluding: Set(item.tags))
            TagSuggestionStrip(title: newTag.isEmpty ? "Recent" : "Tags", tags: suggestions) { tag in
                add(tag)
                newTag = ""
            }
        }
    }

    /// Return in the tag field: add what's typed and put the field away.
    private func addTag() {
        add(newTag)
        newTag = ""
        withNogAnimation(.snappy) { isAddingTag = false }
    }

    /// Adds a tag (cleaned up, no duplicates), to the latest copy of the item so quick
    /// successive adds don't overwrite each other.
    private func add(_ raw: String) {
        guard var current = store.items[item.id], current.addTag(raw) else { return }
        store.update(current)
    }

    private func removeTag(_ tag: String) {
        guard var current = store.items[item.id] else { return }
        withNogAnimation(.snappy) {
            if current.removeTag(tag) { store.update(current) }
        }
    }

    // MARK: Details

    private var detailsSection: some View {
        Section {
            Picker("Estimate", selection: Binding(
                get: { item.estimateMinutes ?? 0 },
                set: { set(\.estimateMinutes, $0 > 0 ? $0 : nil) })) {
                Text("None").tag(0)
                ForEach(Array(Set(NogSettings.timeboxChoices + [item.estimateMinutes ?? 0])).filter { $0 > 0 }.sorted(),
                        id: \.self) { Text(IntervalFormat.amount($0)).tag($0) }
            }
            if item.totalTimeSpent() >= 60 {
                LabeledContent("Time spent", value: DurationFormat.short(item.totalTimeSpent()))
            }
            if item.reminder != nil, item.status != .open {
                Button {
                    showNogSheet = true
                } label: {
                    LabeledContent("Reminders", value: item.status.pausedReason)
                }
                .foregroundStyle(.primary)
            }
        } header: {
            SectionLabel(title: "Details")
        }
        .listRowBackground(Theme.glass)
    }

    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            if let parent = store.parent(of: item) {
                Button {
                    showParentPicker = true
                } label: {
                    Label("Move…", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                Button {
                    set(\.parentID, nil)
                } label: {
                    Label("Take out of \(parent.title)", systemImage: "arrow.up.forward.square")
                }
            } else {
                Button {
                    showParentPicker = true
                } label: {
                    Label("Put inside…", systemImage: "arrow.down.right.square")
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        // Anchored to the ••• button, so the confirmation pops up right here.
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(item.id)
                dismiss()
            }
        } message: {
            Text("Its notes go too. Sub-nogs stay.")
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        let outgoing = item.outgoingLinkTitles
        let backlinks = store.backlinks(to: item)
        if !outgoing.isEmpty {
            GlassSection("Links") {
                ForEach(outgoing, id: \.self) { title in
                    if let target = store.resolve(title: title) {
                        NavigationLink(value: target.id) { Label(target.title, systemImage: "link") }
                    } else {
                        Button {
                            let created = store.createIdea(title: title)
                            router.push(created.id)
                        } label: {
                            Label("Create “\(title)”", systemImage: "plus")
                        }
                    }
                }
            }
        }
        if !backlinks.isEmpty {
            GlassSection("Linked from") {
                ForEach(backlinks) { source in
                    NavigationLink(value: source.id) { Label(source.title, systemImage: "arrow.uturn.left") }
                }
            }
        }
    }
}

// MARK: - State cards

/// The one question you have about an open item: when will it nog me next?
/// Big glowing readout, the rhythm underneath (tap to change it), then Start and Done.
private struct NextNogCard<Actions: View>: View {
    @Environment(ItemStore.self) private var store
    /// Settings › "Ring as an alarm after": which profiles get the rings-through-Silent mark.
    @AppStorage(NogSettings.Key.escalateAfter) private var globalEscalate = 0
    let item: Item
    let edit: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        // The countdown ("in 12 min") changes on the minute counted back from the next nog.
        let next = item.reminder.flatMap { NogSettings.policy.deliveryDates(for: $0, after: .now, limit: 1).first }
        TimelineView(MinuteSchedule(anchor: next, moments: next.map { [$0] } ?? [])) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reminder = item.reminder,
               let next = NogSettings.policy.deliveryDates(for: reminder, after: now, limit: 1).first {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        PanelLabel(text: "Next nog · \(DayFormat.label(next))")
                        GlowReadout(text: next.formatted(date: .omitted, time: .shortened), size: 36)
                    }
                    Spacer()
                    Text(Self.countdown(to: next, now: now))
                        .nogReadout(14)
                        .foregroundStyle(Theme.blue)
                }
                rhythmRow(reminder.repeatSummary.map { "then \($0)" } ?? "once", reminder: reminder)
                if let recurrence = item.recurrence { recurrenceRow(recurrence, start: reminder.start) }
            } else if let reminder = item.reminder {
                // A one-off that has already gone off.
                PanelLabel(text: "Reminded you at \(reminder.start.formatted(date: .omitted, time: .shortened))")
                rhythmRow("pick a new time", reminder: reminder)
            } else if let place = item.place {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        PanelLabel(text: "Waiting for a place", tint: Theme.violet)
                        Text(place.phrase.prefix(1).uppercased() + place.phrase.dropFirst())
                        if PlaceBook.place(named: place.name) == nil {
                            Text("\(place.name) isn't set up. Add it in Settings › Places.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.pink)
                        }
                    }
                    Spacer()
                    Button("Change…", action: edit)
                        .buttonStyle(OutlineButtonStyle(tint: Theme.violet, expands: false))
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        PanelLabel(text: "No reminder")
                    }
                    Spacer()
                    Button("Remind me…", action: edit)
                        .buttonStyle(OutlineButtonStyle(tint: Theme.pink, expands: false))
                }
            }
            PanelActions { actions }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .nogPanel(cornerRadius: 14)
    }

    private func rhythmRow(_ text: String, reminder: Reminder) -> some View {
        Button(action: edit) {
            HStack(spacing: 4) {
                Text(text).foregroundStyle(.primary)
                // A one-off has no rhythm, so no profile to name.
                if reminder.repeatMinutes != nil {
                    let profile = NogProfile.matching(reminder)
                    Text("· \(profile?.label ?? "Custom")").foregroundStyle(Theme.violet)
                    // Its profile can ring through Silent: the same mark as on the profile icons.
                    // ("Ring like an alarm" has its own icon below.)
                    if !reminder.alarm, profile?.breaksSilent(globalEscalateAfter: globalEscalate) == true {
                        Image(systemName: "alarm.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.pink)
                            .accessibilityLabel(NogProfile.breaksSilentSpoken)
                    }
                }
                if reminder.alarm {
                    Image(systemName: "alarm.waves.left.and.right").foregroundStyle(Theme.pink)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
            }
            .font(.subheadline)
            .nogLineLimit(1, accessibilityLines: 2)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Change how this nogs you")
    }

    /// "Comes back every day at 8:00 AM · done 12 times", and a way to skip this time.
    private func recurrenceRow(_ recurrence: Recurrence, start: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "repeat").foregroundStyle(Theme.violet)
                .accessibilityHidden(true)
            Text("Comes back \(recurrence.summary(at: start))"
                 + (item.timesDone > 0 ? " · done \(item.timesDone) time\(item.timesDone == 1 ? "" : "s")" : ""))
                .foregroundStyle(.primary)
            Spacer()
            Button("Skip this time") { store.skipOccurrence(item.id) }
                .font(.subheadline)
                .buttonStyle(.borderless)
                .tint(Theme.violet)
                .accessibilityHint("Moves it to next time without counting it done")
        }
        .font(.subheadline)
        .nogLineLimit(2, accessibilityLines: 4)
    }

    /// "in 12 min", "in 3h 5m", "now"
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        if minutes < 1440 { return minutes % 60 == 0 ? "in \(minutes / 60)h" : "in \(minutes / 60)h \(minutes % 60)m" }
        return "in \(minutes / 1440)d"
    }
}

/// The foot of a timer panel: a hairline, then the panel's buttons.
private struct PanelActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) {
            Divider().overlay(Theme.muted.opacity(0.25))
            content
        }
        .padding(.top, 4)
    }
}

/// Parked in Dream nogs: say so, and offer the way back.
private struct DreamCard<Actions: View>: View {
    let reopen: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    PanelLabel(text: "Someday", tint: Theme.violet)
                    Text("No reminders.")
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Bring back", action: reopen)
                    .buttonStyle(OutlineButtonStyle(tint: Theme.pink, expands: false))
            }
            PanelActions { actions }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .nogPanel(cornerRadius: 14)
    }
}

/// Finished: when, how long it took, and Reopen.
private struct NoggedCard: View {
    let item: Item
    let reopen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                PanelLabel(text: "Done · \(DayFormat.label(item.completed ?? .now))")
                GlowReadout(text: (item.completed ?? .now).formatted(date: .omitted, time: .shortened),
                            size: 28, color: StatusDial.tint(.done), glow: StatusDial.tint(.done))
                if item.totalTimeSpent() >= 60 {
                    Text("took \(DurationFormat.short(item.totalTimeSpent()))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Button {
                reopen()
            } label: {
                Label("Reopen", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(OutlineButtonStyle(tint: Theme.violet, expands: false))
        }
        .padding(16)
        .nogPanel(cornerRadius: 14)
    }
}

/// Pro-app LCD digits: unlit "8"s behind, glowing numbers in front.
struct GlowReadout: View {
    let text: String
    var size: CGFloat = 36
    var color = Theme.lcd
    var glow = Theme.blue

    var body: some View {
        ZStack(alignment: .leading) {
            Text(String(text.map { $0.isNumber ? "8" : $0 })).foregroundStyle(glow.opacity(0.07))
            Text(text)
                .foregroundStyle(color)
                .nogGlow(color: glow.opacity(0.55), radius: 8)
                .nogGlow(color: glow.opacity(0.9), radius: 1)
        }
        .nogReadout(size)
        .monospacedDigit()
        // The unlit "8"s are decoration: VoiceOver reads only the time.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A tag, coloured like its zone on the Map. Long-press to remove.
private struct TagChip: View {
    let tag: String
    let remove: () -> Void

    var body: some View {
        let color = TagPalette.tint(for: tag)
        HStack(spacing: 2) {
            Text("#\(tag)")
                .font(.subheadline)
                .padding(.leading, 12)
            // A visible ✕ on every chip: tap it to take the tag off.
            Button(action: remove) {
                Image(systemName: "xmark")
                    .nogFont(11, weight: .bold)
                    .frame(minWidth: 30, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .foregroundStyle(color)
        .frame(minHeight: 32)
        .background(color.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
        .contextMenu {
            Button(role: .destructive, action: remove) {
                Label("Remove #\(tag)", systemImage: "xmark")
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > maxWidth {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

private struct ParentPicker: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                let candidates = store.items.values
                    .filter { $0.id != item.id && !store.isDescendant($0.id, of: item.id) && $0.status != .done }
                    .filter { search.isEmpty || $0.title.lowercased().contains(search.lowercased()) }
                    .sorted { $0.updated > $1.updated }
                ForEach(candidates) { candidate in
                    Button(candidate.title) {
                        var updated = store.items[item.id] ?? item
                        updated.parentID = candidate.id
                        store.update(updated)
                        dismiss()
                    }
                }
            }
            .nogListStyle()
            .searchable(text: $search)
            .navigationTitle("Put inside…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// A Form/List section with a frosted row background and a HUD label.
struct GlassSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            SectionLabel(title: title)
        }
        .listRowBackground(Theme.glass)
    }
}
