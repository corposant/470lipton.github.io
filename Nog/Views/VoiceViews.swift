import SwiftUI

/// The Voice section on a nog's page: each recording with Play, then Record.
struct VoiceNotesSection: View {
    @Environment(ItemStore.self) private var store
    let item: Item
    @State private var showRecorder = false

    var body: some View {
        Section {
            ForEach(Array(item.voiceNotes.enumerated()), id: \.element.file) { index, note in
                VoiceNoteRow(note: note, name: item.voiceNotes.count == 1 ? "Voice note" : "Voice \(index + 1)")
                    .swipeActions { deleteButton(note) }
                    .contextMenu { deleteButton(note) }
            }
            Button {
                showRecorder = true
            } label: {
                Label("Record", systemImage: "mic")
                    .foregroundStyle(Theme.pink)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Record voice note")
        } header: {
            SectionLabel(title: "Voice")
        }
        .listRowBackground(Theme.glass)
        .sheet(isPresented: $showRecorder) {
            RecordSheet { recording in
                store.attachVoiceNote(recording, to: item.id)
                AccessibilityNotification.Announcement("Voice note saved").post()
            }
        }
        .onDisappear {
            if let playing = VoicePlayer.shared.playing, item.voiceNotes.contains(where: { $0.file == playing }) {
                VoicePlayer.shared.stop()
            }
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

/// Records as soon as it opens. Stop saves; Cancel throws it away. Leaving the app saves too,
/// so a recording is never lost to a notification tap.
struct RecordSheet: View {
    let onSave: (VoiceRecording) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var recorder = VoiceRecorder()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                switch recorder.state {
                case .denied: denied
                case .failed: failed
                default: recording
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background { NogBackground() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        // A swipe down mustn't silently drop or keep a recording: Stop or Cancel decides.
        .interactiveDismissDisabled(recorder.state == .recording || recorder.state == .asking)
        .task {
            VoicePlayer.shared.stop()
            await recorder.start()
        }
        .onChange(of: recorder.state) { _, state in
            if state == .stoppedItself { save() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, recorder.state == .recording { save() }
        }
        .onDisappear { recorder.cancel() }
    }

    private var recording: some View {
        VStack(spacing: 24) {
            HStack(spacing: 8) {
                Circle().fill(Theme.pink).frame(width: 10, height: 10)
                    .nogGlow(color: Theme.pink, radius: 4)
                    .opacity(recorder.state == .recording ? 1 : 0.3)
                Text(recorder.state == .recording ? "RECORDING" : "STARTING")
                    .font(.nogLabel)
                    .tracking(2)
                    .foregroundStyle(Theme.pink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = recorder.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
                Text(VoiceNote.clock(elapsed))
                    .nogReadout(48)
                    .foregroundStyle(Theme.lcd)
                    .accessibilityLabel(Duration.seconds(Int(elapsed))
                        .formatted(.units(allowed: [.minutes, .seconds], width: .wide)))
            }

            // How loud it's hearing you; just a reassurance that it's working.
            Capsule()
                .fill(Theme.edge)
                .frame(maxWidth: 220, maxHeight: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(Theme.synth)
                            .frame(width: proxy.size.width * recorder.level)
                    }
                }
                .accessibilityHidden(true)

            Button(action: save) {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.pink)
                        .nogFrame(width: 26, height: 26)
                        .nogFrame(width: 76, height: 76)
                        .overlay(Circle().strokeBorder(Theme.synth, lineWidth: 2))
                        .nogGlow(color: Theme.pink.opacity(0.35), radius: 10)
                    Text("STOP").font(.nogTitle(13)).tracking(2).foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.state != .recording)
            .accessibilityLabel("Stop and save")
        }
    }

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
        }
    }

    private var failed: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").nogFont(34).foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            Text("Couldn't record. Try again.")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
    }

    private func save() {
        if let recording = recorder.stop() {
            onSave(recording)
        }
        dismiss()
    }
}
