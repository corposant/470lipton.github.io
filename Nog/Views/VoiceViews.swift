import SwiftUI

/// Voice notes as rows inside the Notes section, each recording with Play.
/// Not a section of its own, so typed and spoken notes sit together.
struct VoiceNoteRows: View {
    @Environment(ItemStore.self) private var store
    let item: Item

    // Recording starts from the mic beside the notes (ItemDetailView), which also opens the
    // recorder straight away for a voice nog. Stop-on-leave is on the page too, since a row
    // scrolled out of sight also "disappears".
    var body: some View {
        ForEach(Array(item.voiceNotes.enumerated()), id: \.element.file) { index, note in
            VoiceNoteRow(note: note, name: item.voiceNotes.count == 1 ? "Voice note" : "Voice \(index + 1)")
                .swipeActions { deleteButton(note) }
                .contextMenu { deleteButton(note) }
        }
    }

    private func deleteButton(_ note: VoiceNote) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            if VoicePlayer.shared.playing == note.file { VoicePlayer.shared.stop() }
            store.removeVoiceNote(note.file, from: item.id)
        }
    }
}

/// ▶︎ Voice note ··· 0:42. Tap anywhere on the row to play or stop.
struct VoiceNoteRow: View {
    @Environment(ItemStore.self) private var store
    let note: VoiceNote
    let name: String

    private var player: VoicePlayer { .shared }
    private var isPlaying: Bool { player.playing == note.file }
    private var isLoading: Bool { player.loading == note.file }
    private var didFail: Bool { player.failed == note.file }

    var body: some View {
        Button {
            Task { await player.toggle(note, store: store) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        CircleOutlineIcon(systemName: isPlaying ? "stop.fill" : "play.fill", tint: Theme.pink)
                    }
                }
                .nogFrame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    if didFail {
                        Text("Couldn't play. Try again.")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                if isPlaying {
                    // Counts down while it plays.
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(VoiceNote.clock(TimeInterval(note.seconds) - player.currentTime))
                    }
                    .nogReadout(15)
                    .foregroundStyle(Theme.pink)
                } else {
                    Text(note.clock)
                        .nogReadout(15)
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(note.spokenLength)")
        .accessibilityValue(isPlaying ? "Playing" : isLoading ? "Loading" : didFail ? "Couldn't play" : "")
        .accessibilityHint(isPlaying ? "Stops it." : "Plays it.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { Task { await player.toggle(note, store: store) } }
    }
}

/// The recorder: a glass panel that rises over the nog. Records as soon as it opens.
/// Big digits, a live waveform, and three controls: discard, pause, Save. Save tucks the
/// recording into the nog underneath. Leaving the app saves too, so nothing is lost.
struct RecorderPanel: View {
    let onSave: (VoiceRecording) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var recorder = VoiceRecorder()
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 16) {
            switch recorder.state {
            case .denied: denied
            case .failed: failed
            default: live
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A short sheet is Liquid Glass on its own; the nog stays visible above it.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(400)])
        .presentationDragIndicator(.visible)
        .tint(Theme.pink)
        // A swipe down mustn't silently drop or keep a recording: Save or the bin decides.
        .interactiveDismissDisabled(recorder.isLive || recorder.state == .asking)
        .task {
            VoicePlayer.shared.stop()
            await recorder.start()
        }
        .onChange(of: recorder.state) { _, state in
            if state == .stoppedItself { save() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, recorder.isLive { save() }
        }
        .onDisappear { recorder.cancel() }
        .nogFeedback(.impact(weight: .medium), trigger: recorder.state) { _, new in new == .recording || new == .paused }
    }

    // MARK: Recording

    private var live: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(Theme.pink).frame(width: 9, height: 9)
                    .nogGlow(color: Theme.pink, radius: 4)
                    .opacity(recorder.state == .recording ? 1 : 0.3)
                PanelLabel(text: statusWord, tint: recorder.state == .recording ? Theme.pink : Theme.panelLabel)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            // The readout: a recessed well with lit digits and the waveform under them.
            VStack(spacing: 10) {
                // The same lit digits as the reminder tuner and the Doing timer.
                GlowReadout(text: VoiceNote.clock(recorder.elapsed.rounded(.down), padded: true)
                    + String(format: ".%d", Int(recorder.elapsed * 10) % 10), size: 44)
                    .accessibilityLabel("Time")
                    .accessibilityValue(Duration.seconds(Int(recorder.elapsed))
                        .formatted(.units(allowed: [.minutes, .seconds], width: .wide)))

                Waveform(levels: recorder.levels, paused: recorder.state == .paused)
                    .frame(height: 64)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .recessedWell(cornerRadius: 14)

            HStack {
                Button {
                    if recorder.elapsed < 3 { discard() } else { confirmDiscard = true }
                } label: {
                    CircleOutlineIcon(systemName: "trash", tint: Theme.muted, size: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard recording")
                .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive, action: discard)
                    Button("Keep recording", role: .cancel) {}
                }
                .frame(maxWidth: .infinity)

                Button(action: recorder.togglePause) {
                    ZStack {
                        Circle().strokeBorder(Theme.synth, lineWidth: 2)
                        Circle().fill(Theme.pink).padding(8)
                        // Base colour on pink: readable in both themes.
                        Image(systemName: recorder.state == .paused ? "mic.fill" : "pause.fill")
                            .nogFont(24, weight: .bold)
                            .foregroundStyle(Theme.base)
                    }
                    .nogFrame(width: 80, height: 80)
                    .nogGlow(color: Theme.pink.opacity(0.45), radius: 12)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!recorder.isLive)
                .accessibilityLabel(recorder.state == .paused ? "Resume recording" : "Pause recording")
                .frame(maxWidth: .infinity)

                // Same button as SAVE on New Nog.
                Button(action: save) {
                    Text("SAVE")
                }
                .buttonStyle(GradientOutlineButtonStyle())
                .disabled(!recorder.isLive)
                .opacity(recorder.isLive ? 1 : 0.45)
                .accessibilityLabel("Save recording")
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var statusWord: String {
        switch recorder.state {
        case .recording: "RECORDING"
        case .paused: "PAUSED"
        default: "STARTING"
        }
    }

    // MARK: Problems

    private var denied: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash").nogFont(34).foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            Text("Microphone is off for Nog.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(OutlineButtonStyle(expands: false))
            Button("Close") { dismiss() }
                .buttonStyle(OutlineButtonStyle(tint: Theme.muted, expands: false))
        }
        .frame(maxHeight: .infinity)
    }

    private var failed: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").nogFont(34).foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            Text("Couldn't record. Try again.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(OutlineButtonStyle(tint: Theme.muted, expands: false))
        }
        .frame(maxHeight: .infinity)
    }

    private func save() {
        if let recording = recorder.stop() { onSave(recording) }
        dismiss()
    }

    private func discard() {
        recorder.cancel()
        dismiss()
    }
}

/// The last few seconds of loudness as bars, newest at the right, scrolling left as you talk.
/// With Reduce Motion or Low stimulation it's one steady level bar instead.
struct Waveform: View {
    let levels: [Float]
    var paused = false

    var body: some View {
        if Calm.reducesMotion {
            GeometryReader { proxy in
                Capsule().fill(Theme.edgeStrong)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.synth)
                            .frame(width: proxy.size.width * CGFloat(paused ? 0 : levels.last ?? 0))
                    }
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
            }
        } else {
            Canvas { context, size in
                let step: CGFloat = 5, barWidth: CGFloat = 3
                let count = Int(size.width / step)
                let shown = levels.suffix(count)
                let mid = size.height / 2
                // Bars fill from the left until the well is full, then scroll.
                for (i, level) in shown.enumerated() {
                    let h = max(3, CGFloat(level) * size.height)
                    let rect = CGRect(x: CGFloat(i) * step, y: mid - h / 2, width: barWidth, height: h)
                    let recent = shown.count - i <= 6
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(paused ? Theme.muted : recent ? Theme.pink : Theme.violet))
                }
                // The baseline still to come.
                let startX = CGFloat(shown.count) * step
                if startX < size.width {
                    context.fill(Path(CGRect(x: startX, y: mid - 0.5, width: size.width - startX, height: 1)),
                                 with: .color(Theme.edgeStrong))
                }
            }
        }
    }
}

/// Which voice nog the sheet is showing.
struct VoiceNogID: Identifiable {
    let id: UUID
    /// Named "Voice nog 8:44 AM" because nothing was typed.
    var untitled = false
}

/// A brand-new voice nog, opened from the mic on New Nog: the nog's page in a sheet, already
/// recording. Cancel throws the nog away; Save keeps it. (It's saved from the start, so a
/// swipe down or a crash keeps it too.)
struct VoiceNogSheet: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    var untitled = false
    var onCancel: () -> Void = {}
    @State private var confirmCancel = false

    var body: some View {
        NavigationStack {
            ItemDetailView(id: id, autoRecord: true, showsMenu: false)
                .navigationDestination(for: UUID.self) { ItemDetailView(id: $0) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            if store.items[id]?.voiceNotes.isEmpty == false { confirmCancel = true } else { cancel() }
                        }
                        .confirmationDialog("Delete this voice nog?", isPresented: $confirmCancel, titleVisibility: .visible) {
                            Button("Delete", role: .destructive, action: cancel)
                            Button("Keep", role: .cancel) {}
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { dismiss() }
                    }
                }
        }
        .tint(Theme.pink)
        .presentationDragIndicator(.visible)
        .onDisappear(perform: dropIfEmpty)
    }

    /// No recording, no words, no notes (mic denied, or the recording binned): nothing to
    /// remind you of, so don't leave a "Voice nog 8:44 AM" nogging you about nothing.
    private func dropIfEmpty() {
        guard untitled, let item = store.items[id], item.voiceNotes.isEmpty,
              item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              store.children(of: id).isEmpty,
              item.title.hasPrefix(VoiceNote.captureTitlePrefix) else { return }
        store.delete(id)
        onCancel()
    }

    private func cancel() {
        VoicePlayer.shared.stop()
        store.delete(id)
        onCancel()
        dismiss()
    }
}
