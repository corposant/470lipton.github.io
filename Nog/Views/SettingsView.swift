import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import UIKit
import UserNotifications

/// Settings: the few things most people change, on one page. Everything else is
/// under Advanced.
struct SettingsView: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Default style for new things
    @AppStorage(NogSettings.firstDelayKey) private var firstDelay = NogSettings.defaultFirstDelay
    @AppStorage(NogSettings.repeatKey) private var repeatMinutes = NogSettings.defaultRepeat
    @AppStorage(NogSettings.curveKey) private var curve: RepeatCurve = .steady
    @AppStorage(NogSettings.escalateKey) private var profileEscalate = -1
    @AppStorage(NogSettings.silentKey) private var profileSilent = false
    @State private var showMoreStyles = false
    // Quiet hours
    @AppStorage(NogSettings.Key.quietEnabled) private var quietEnabled = false
    @AppStorage(NogSettings.Key.quietStart) private var quietStart = 22 * 60
    @AppStorage(NogSettings.Key.quietEnd) private var quietEnd = 7 * 60
    @AppStorage(NogSettings.Key.quietWeekends) private var quietWeekends = false
    // Silence
    @State private var showSilence = false
    @AppStorage(NogSettings.silencedUntilKey) private var silencedUntil: Double = 0
    // Calm
    @AppStorage(Calm.lowStimulationKey) private var lowStimulation = false
    @AppStorage(Calm.hapticsKey) private var haptics = true

    private var currentProfile: NogProfile? {
        NogProfile.allCases.first {
            $0.firstDelayMinutes == firstDelay && $0.repeatMinutes == repeatMinutes
                && $0.curve == curve && ($0.escalateAfter ?? -1) == profileEscalate
                && $0.silent == profileSilent
        }
    }

    var body: some View {
        NavigationStack {
            List {
                style
                quiet
                calm
                Section {
                    NavigationLink {
                        PlacesView()
                    } label: {
                        Label("Places", systemImage: "location")
                    }
                    NavigationLink {
                        HowToNogView()
                    } label: {
                        Label("How to use Nog", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        AdvancedSettingsPage()
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                    }
                }
                .listRowBackground(Theme.glass)
                about
            }
            .nogListStyle()
            .tint(Theme.pink)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onDisappear { Task { await store.syncNow() } }
        }
    }

    // MARK: How firm

    private var style: some View {
        let current = currentProfile
        // The main four, plus the current one if it's one of the others.
        let shown = showMoreStyles ? NogProfile.allCases
            : NogProfile.mainCases + (current.map { NogProfile.mainCases.contains($0) ? [] : [$0] } ?? [])
        return Section {
            ForEach(shown) { profile in
                Button {
                    firstDelay = profile.firstDelayMinutes
                    repeatMinutes = profile.repeatMinutes
                    curve = profile.curve
                    profileEscalate = profile.escalateAfter ?? -1
                    profileSilent = profile.silent
                } label: {
                    ProfileCard(profile: profile, isSelected: current == profile)
                }
                .buttonStyle(.plain)
            }
            Button(showMoreStyles ? "Fewer styles" : "More styles") {
                withNogAnimation(.snappy) { showMoreStyles.toggle() }
            }
            .font(.subheadline)
        } header: {
            SectionLabel(title: "How firm")
        } footer: {
            Text(current == nil
                 ? "You've set a custom rhythm under Advanced › Timing & alerts. Pick a style to go back."
                 : "New things you add start like this. Each item can change on its own page.")
        }
        .listRowBackground(Theme.glass)
    }

    // MARK: Quiet

    private var quiet: some View {
        Section {
            Toggle("Quiet hours", isOn: $quietEnabled)
            if quietEnabled {
                TimeTunerRow(title: "From", minutes: $quietStart)
                TimeTunerRow(title: "Until", minutes: $quietEnd)
                Toggle("All weekend", isOn: $quietWeekends)
            }
            Button {
                showSilence = true
            } label: {
                HStack {
                    Label("Silence everything", systemImage: "bell.slash")
                    Spacer()
                    Text(silencedUntil == 0 || Date(timeIntervalSinceReferenceDate: silencedUntil) <= .now
                         ? "off"
                         : NogSettings.silenceLabel(Date(timeIntervalSinceReferenceDate: silencedUntil))
                            .replacingOccurrences(of: "Silenced ", with: ""))
                        .font(.nogMeta)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .sheet(isPresented: $showSilence) { SilenceSheet() }
        } header: {
            SectionLabel(title: "Quiet")
        } footer: {
            Text("Nothing reminds you or rings during quiet hours. Anything due waits until they end.")
        }
        .listRowBackground(Theme.glass)
    }

    // MARK: Calm

    private var calm: some View {
        Section {
            Toggle(isOn: $lowStimulation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Low stimulation")
                    Text("No glow, background haze, motion or vibration.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
            }
            Toggle("Vibration", isOn: $haptics)
                .disabled(lowStimulation)
        } header: {
            SectionLabel(title: "Calm")
        } footer: {
            Text("Nog also follows Reduce Motion, Reduce Transparency and Increase Contrast in Settings → Accessibility.")
        }
        .listRowBackground(Theme.glass)
        .tint(Theme.blue)
    }

    // MARK: About

    private var about: some View {
        Section {
            LabeledContent("Version",
                           value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                .font(.nogMeta)
        } footer: {
            Text("Nog reminds you until it's done.")
        }
        .listRowBackground(Theme.glass)
    }
}

/// Settings › Advanced: everything most people never need to touch.
struct AdvancedSettingsPage: View {
    @Environment(ItemStore.self) private var store
    @AppStorage(ThemeMode.key) private var themeMode: ThemeMode = .auto
    @AppStorage(NogSettings.firstDelayKey) private var firstDelay = NogSettings.defaultFirstDelay
    @AppStorage(NogSettings.repeatKey) private var repeatMinutes = NogSettings.defaultRepeat
    @AppStorage(NogSettings.curveKey) private var curve: RepeatCurve = .steady
    @AppStorage(NogSettings.timeboxKey) private var timebox = NogSettings.defaultTimebox
    @State private var appIcon = AppIconChoice.current(alternateIconName: UIApplication.shared.alternateIconName)
    @State private var storageMode = StorageMode.current
    @State private var isSwitchingStorage = false
    @State private var showSilence = false
    @AppStorage(NogSettings.silencedUntilKey) private var silencedUntil: Double = 0
    @AppStorage(Calm.lowStimulationKey) private var lowStimulation = false
    @AppStorage(Calm.hapticsKey) private var haptics = true

    @AppStorage(AppTab.mapTabKey) private var showMapTab = false

    var body: some View {
        List {
            behavior
            Section {
                Toggle(isOn: $showMapTab) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Map tab")
                        Text("See everything as a mind map you can arrange.")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.teal)
            } header: {
                SectionLabel(title: "Tabs")
            }
            .listRowBackground(Theme.glass)
            appearance
            storage
            system
            #if DEBUG
            developer
            #endif
        }
        .nogListStyle()
        .navigationTitle("Advanced")
    }

    // MARK: Appearance

    private var appearance: some View {
        Section {
            Picker("Theme", selection: $themeMode) {
                ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Theme.glass)

            HStack(spacing: 14) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button {
                        Task { await setIcon(choice) }
                    } label: {
                        VStack(spacing: 8) {
                            Image(choice.previewImage)
                                .resizable()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(appIcon == choice ? AnyShapeStyle(Theme.synth) : AnyShapeStyle(Theme.edge),
                                                      lineWidth: appIcon == choice ? 2 : 1)
                                        .padding(-4)
                                }
                            Text(choice.label)
                                .font(.caption)
                                .foregroundStyle(appIcon == choice ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .listRowBackground(Theme.glass)
        } header: {
            SectionLabel(title: "Appearance")
        } footer: {
            Text("Auto follows your iPhone's Light/Dark setting.")
        }
    }

    private func setIcon(_ choice: AppIconChoice) async {
        guard choice != appIcon, UIApplication.shared.supportsAlternateIcons else { return }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
            appIcon = choice
        } catch {
            print("Nog: couldn't change icon: \(error)")
        }
    }

    // MARK: Storage

    private var storage: some View {
        Section {
            Picker("Keep items", selection: Binding(
                get: { storageMode },
                set: { mode in
                    storageMode = mode
                    isSwitchingStorage = true
                    Task {
                        await store.setStorage(mode)
                        isSwitchingStorage = false
                    }
                })) {
                ForEach(StorageMode.allCases) { Text($0.label).tag($0) }
            }
            .disabled(isSwitchingStorage)
            .listRowBackground(Theme.glass)

            HStack {
                Label(store.isUsingICloud ? "Syncing with iCloud Drive" : "Stored on this iPhone",
                      systemImage: store.isUsingICloud ? "icloud" : "iphone")
                Spacer()
                if isSwitchingStorage { ProgressView() }
                Text("\(store.items.count) items").font(.nogMeta).foregroundStyle(.secondary)
            }
            .listRowBackground(Theme.glass)
        } header: {
            SectionLabel(title: "Storage")
        } footer: {
            if storageMode == .iCloud && !store.isUsingICloud && !isSwitchingStorage {
                Text("iCloud isn't available, so items stay on this iPhone. Check you're signed in to iCloud with iCloud Drive on.")
            } else {
                Text(store.isUsingICloud
                     ? "Every item is a plain Markdown file in iCloud Drive → Nog → Items, also visible on your Mac."
                     : "Every item is a plain Markdown file in Files → On My iPhone → Nog → Items. Switching back to iCloud merges, keeping the newest edits.")
            }
        }
    }

    // MARK: Behavior

    private var behavior: some View {
        Section {
            NavigationLink {
                NogsAlertsPage()
            } label: {
                row("Timing & alerts", "bell.badge", Theme.pink, detail: nil)
            }
            NavigationLink {
                DoingPage()
            } label: {
                row("Doing (the ▶︎ timer)", "play.circle", Theme.blue,
                    detail: timebox > 0 ? "\(IntervalFormat.amount(timebox)) box" : "open-ended")
            }
        } header: {
            SectionLabel(title: "Reminders")
        }
        .listRowBackground(Theme.glass)
    }

    // MARK: System

    private var system: some View {
        Section {
            NavigationLink {
                PermissionsPage()
            } label: {
                row("Permissions", "checkmark.shield", Theme.blue, detail: nil)
            }
            NavigationLink {
                SiriPage()
            } label: {
                row("Siri & Shortcuts", "waveform", Theme.violet, detail: nil)
            }
        } header: {
            SectionLabel(title: "System")
        }
        .listRowBackground(Theme.glass)
    }

    #if DEBUG
    // MARK: Developer (debug builds only)

    private var developer: some View {
        Section {
            Button("Add 300 test items") { store.addTestItems() }
            Button("Remove test items", role: .destructive) { store.removeTestItems() }
        } header: {
            SectionLabel(title: "Developer")
        } footer: {
            Text("Debug builds only. Test items are tagged #perftest.")
        }
        .listRowBackground(Theme.glass)
    }
    #endif

    private func row(_ title: String, _ icon: String, _ tint: Color, detail: String?) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            Spacer()
            if let detail {
                Text(detail).font(.nogMeta).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pages

/// Every knob for nogs, alarms and alerts.
private struct NogsAlertsPage: View {
    @Environment(ItemStore.self) private var store
    // New captures
    @AppStorage(NogSettings.firstDelayKey) private var firstDelay = NogSettings.defaultFirstDelay
    @AppStorage(NogSettings.repeatKey) private var repeatMinutes = NogSettings.defaultRepeat
    @AppStorage(NogSettings.curveKey) private var curve: RepeatCurve = .steady
    @AppStorage(NogSettings.escalateKey) private var profileEscalate = -1
    @AppStorage(NogSettings.silentKey) private var profileSilent = false
    @State private var showFineTune = false
    // Quiet hours
    @AppStorage(NogSettings.Key.quietEnabled) private var quietEnabled = false
    @AppStorage(NogSettings.Key.quietStart) private var quietStart = 22 * 60
    @AppStorage(NogSettings.Key.quietEnd) private var quietEnd = 7 * 60
    @AppStorage(NogSettings.Key.quietWeekends) private var quietWeekends = false
    // Timing
    @AppStorage(NogSettings.Key.headsUp) private var headsUp = 0
    @AppStorage(NogSettings.Key.escalateAfter) private var escalateAfter = 0
    @AppStorage(NogSettings.Key.snoozeMinutes) private var snoozeMinutes = 60
    @AppStorage(NogSettings.Key.morningMinutes) private var morningMinutes = 9 * 60
    // How they look and sound
    @AppStorage(NogSettings.Key.timeSensitive) private var timeSensitive = true
    @AppStorage(NogSettings.Key.sound) private var sound = true
    @AppStorage(NogSettings.Key.showTitles) private var showTitles = true
    @AppStorage(NogSettings.Key.badge) private var badge = false

    var body: some View {
        List {
            Section {
                // Daily starts a day out, so the range stretches to fit.
                Stepper(value: $firstDelay, in: 0...max(240, firstDelay), step: 1) {
                    LabeledContent("First reminder", value: firstDelay == 0 ? "Right away" : "after \(IntervalFormat.amount(firstDelay))")
                }
                Picker("Then", selection: $repeatMinutes) {
                    ForEach(Array(Set(NogSettings.repeatChoices + [repeatMinutes])).sorted(), id: \.self) {
                        Text(NogSettings.repeatLabel($0)).tag($0)
                    }
                }
                if repeatMinutes > 0 {
                    Picker("Style", selection: $curve) {
                        ForEach(RepeatCurve.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Silent (no sound, not Time Sensitive)", isOn: $profileSilent)
            } header: {
                SectionLabel(title: currentProfile == nil ? "Default rhythm · Custom" : "Default rhythm · \(currentProfile!.label)")
            } footer: {
                Text("Changing these makes your default a custom rhythm. Pick a style on the main Settings page to go back.")
            }
            .listRowBackground(Theme.glass)

            Section {
                Picker("Heads-up before", selection: $headsUp) {
                    ForEach(NogSettings.headsUpChoices, id: \.self) { Text($0 == 0 ? "Off" : IntervalFormat.amount($0)).tag($0) }
                }
                Picker("Ring as an alarm after", selection: $escalateAfter) {
                    ForEach(NogSettings.escalateChoices, id: \.self) { Text($0 == 0 ? "Never" : "\($0) ignored nogs").tag($0) }
                }
                Picker("Snooze button", selection: $snoozeMinutes) {
                    ForEach(NogSettings.snoozeChoices, id: \.self) { Text(IntervalFormat.amount($0)).tag($0) }
                }
                TimeTunerRow(title: "“Morning” means", minutes: $morningMinutes)
            } header: {
                SectionLabel(title: "Timing")
            } footer: {
                Text("Heads-up: a gentle note before a dated nog starts. Ring as an alarm: if you keep ignoring an item, its nogs become alarms that break through Silent and Focus. Snoozing resets the count.")
            }
            .listRowBackground(Theme.glass)

            Section {
                Toggle("Time Sensitive", isOn: $timeSensitive)
                Toggle("Sound", isOn: $sound)
                Toggle("Show titles on Lock Screen", isOn: $showTitles)
                Toggle("Badge the app icon", isOn: $badge)
            } header: {
                SectionLabel(title: "Notifications")
            } footer: {
                Text("Time Sensitive lets nogs through Focus (also allow it in iOS Settings → Notifications → Nog). With titles hidden, the Lock Screen just says something's nogging you.")
            }
            .listRowBackground(Theme.glass)
            .tint(Theme.pink)
        }
        .nogListStyle()
        .tint(Theme.pink)
        .navigationTitle("Timing & alerts")
        .onDisappear {
            NotificationScheduler.shared.registerCategories()
            Task { await store.syncNow() }
        }
    }
}

extension NogsAlertsPage {
    fileprivate var currentProfile: NogProfile? {
        NogProfile.allCases.first {
            $0.firstDelayMinutes == firstDelay && $0.repeatMinutes == repeatMinutes
                && $0.curve == curve && ($0.escalateAfter ?? -1) == profileEscalate
                && $0.silent == profileSilent
        }
    }
}

/// One profile: icon, name, one-line description, checkmark when chosen.
struct ProfileCard: View {
    let profile: NogProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.systemImage)
                .nogFont(16, weight: .semibold)
                .foregroundStyle(tint)
                .nogFrame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label).font(.headline)
                Text(profile.summary).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? tint : Theme.muted.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch profile {
        case .hush, .whisper, .daily: Theme.blue
        case .steady, .easing, .building: Theme.violet
        case .hyperfocus, .unhinged: Theme.pink
        }
    }
}


private struct DoingPage: View {
    @Environment(ItemStore.self) private var store
    @AppStorage(NogSettings.timeboxKey) private var timebox = NogSettings.defaultTimebox
    @AppStorage(NogSettings.Key.timesUpEvery) private var timesUpEvery = 5
    @AppStorage(NogSettings.Key.checkInEvery) private var checkInEvery = 60
    @AppStorage(NogSettings.Key.liveActivity) private var liveActivity = true

    var body: some View {
        List {
            Section {
                Picker("Default timebox", selection: $timebox) {
                    Text("Open-ended").tag(0)
                    ForEach(NogSettings.timeboxChoices, id: \.self) { Text(IntervalFormat.amount($0)).tag($0) }
                }
            } header: {
                SectionLabel(title: "▶︎ Doing")
            } footer: {
                Text("Nog suggests, in order: the item's estimate, how long similar items took you (same #tag or project), a short box if it's urgent or overdue, then this default.")
            }
            .listRowBackground(Theme.glass)

            Section {
                Picker("“Time's up” repeats", selection: $timesUpEvery) {
                    ForEach(NogSettings.timesUpChoices, id: \.self) { Text("every \(IntervalFormat.short($0))").tag($0) }
                }
                Picker("Open-ended check-in", selection: $checkInEvery) {
                    ForEach(NogSettings.checkInChoices, id: \.self) { Text($0 == 0 ? "Off" : "every \(IntervalFormat.short($0))").tag($0) }
                }
                Toggle("Live Activity", isOn: $liveActivity)
            } header: {
                SectionLabel(title: "While you're on it")
            } footer: {
                Text("Live Activity shows your timer on the Lock Screen and in the Dynamic Island.")
            }
            .listRowBackground(Theme.glass)
            .tint(Theme.blue)
        }
        .nogListStyle()
        .navigationTitle("Doing")
        .onDisappear { Task { await store.syncNow() } }
    }
}

private struct PermissionsPage: View {
    @Environment(ItemStore.self) private var store
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var pending = 0
    @State private var alarmsAuthorized = false
    @State private var liveActivities = false

    var body: some View {
        List {
            Section {
                LabeledContent("Notifications", value: label(for: notifications))
                LabeledContent("Alarms", value: alarmsAuthorized ? "Allowed" : "Not allowed")
                LabeledContent("Live Activities", value: liveActivities ? "On" : "Off")
                if notifications == .denied || !liveActivities {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                if !alarmsAuthorized {
                    Button("Allow alarms") {
                        Task {
                            await AlarmScheduler.shared.requestAuthorization()
                            await refresh()
                        }
                    }
                }
            } header: {
                SectionLabel(title: "Permissions")
            } footer: {
                Text("For nogs that break through Focus, also turn on Time Sensitive in iOS Settings → Notifications → Nog.")
            }
            .listRowBackground(Theme.glass)

            Section {
                LabeledContent("Scheduled nogs", value: "\(pending)")
                Button("Re-sync reminders") {
                    Task {
                        await store.syncNow()
                        await refresh()
                    }
                }
            } header: {
                SectionLabel(title: "Diagnostics")
            }
            .listRowBackground(Theme.glass)
        }
        .nogListStyle()
        .navigationTitle("Permissions")
        .task { await refresh() }
    }

    private func refresh() async {
        notifications = await NotificationScheduler.shared.authorizationStatus()
        pending = await NotificationScheduler.shared.pendingCount()
        alarmsAuthorized = AlarmScheduler.shared.isAuthorized
        liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .provisional: return "Quiet"
        case .ephemeral: return "Temporary"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }
}

/// Every phrase here is one Siri knows (see NogShortcuts), so nobody has to
/// remember them or guess. Start each with "Hey Siri".
private struct SiriPage: View {
    @AppStorage("siriTip.capture") private var showSiriTip = true

    var body: some View {
        List {
            group("Add something", footer: "Siri asks what you want to add.", [
                "Take a Nog",
                "Add something to Nog",
                "Take a note in Nog",
            ])
            group("Hear your list", footer: "You can also say today, this week, unscheduled, or what I'm doing.", [
                "What's next in Nog",
                "Read my Nog",
                "Read this week in Nog",
            ])
            group("Finish or start", footer: "Say the item's name, or leave it out and Siri asks which one.", [
                "Mark done in Nog",
                "Finish call mom in Nog",
                "Start something in Nog",
                "Work on write report in Nog",
            ])
            group("Quiet things down", footer: "Also for two hours, five hours, twelve hours, or until I turn it back on.", [
                "Pause Nog for an hour",
                "Silence Nog",
                "Turn Nog back on",
            ])
            group("With Apple Intelligence", footer: "Any item with sub-nogs works as a list for Siri.", [
                "Remind me in Nog to call mom tomorrow at 3",
                "Add milk to my Groceries list in Nog",
                "Mark this as done",
            ])
            Section {
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                if !showSiriTip {
                    Button("Show the Siri tip on New Nog again") { showSiriTip = true }
                }
            } footer: {
                Text("If Siri doesn't understand, open Nog once so Siri learns its phrases, then try again. Assign “Quick Capture” to the Action Button in iOS Settings → Action Button → Shortcut.")
            }
            .listRowBackground(Theme.glass)
        }
        .nogListStyle()
        .navigationTitle("Siri & Shortcuts")
    }

    private func group(_ title: String, footer: String, _ phrases: [String]) -> some View {
        Section {
            ForEach(phrases, id: \.self) { text in
                Label("“\(text)”", systemImage: "quote.bubble").foregroundStyle(.primary)
            }
        } header: {
            SectionLabel(title: title)
        } footer: {
            Text(footer)
        }
        .listRowBackground(Theme.glass)
    }
}
