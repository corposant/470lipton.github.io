import ActivityKit
import AlarmKit
import SwiftUI
import UIKit
import UserNotifications

/// The control panel.
struct SettingsView: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ThemeMode.key) private var themeMode: ThemeMode = .auto
    @AppStorage(NogSettings.firstDelayKey) private var firstDelay = NogSettings.defaultFirstDelay
    @AppStorage(NogSettings.repeatKey) private var repeatMinutes = NogSettings.defaultRepeat
    @AppStorage(NogSettings.curveKey) private var curve: RepeatCurve = .steady
    @AppStorage(NogSettings.timeboxKey) private var timebox = NogSettings.defaultTimebox
    @State private var appIcon = AppIconChoice.current(alternateIconName: UIApplication.shared.alternateIconName)
    @State private var storageMode = StorageMode.current
    @State private var isSwitchingStorage = false

    var body: some View {
        NavigationStack {
            List {
                appearance
                storage
                behavior
                system
                about
            }
            .nogListStyle()
            .navigationTitle("Control Panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
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
                Text("iCloud isn't available, so items stay on this iPhone. Check you're signed in with iCloud Drive on (iCloud sync also needs a build signed with a paid developer account).")
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
                row("Nogs & alerts", "bell.badge", Theme.pink,
                    detail: NogSettings.defaultProfile?.label.lowercased() ?? "custom")
            }
            NavigationLink {
                DoingPage()
            } label: {
                row("Nogitivity", "play.circle", Theme.blue,
                    detail: timebox > 0 ? "\(IntervalFormat.amount(timebox)) box" : "open-ended")
            }
            NavigationLink {
                CaptureCheatSheet()
            } label: {
                row("Capture shortcuts", "text.cursor", Theme.violet, detail: nil)
            }
        } header: {
            SectionLabel(title: "Behavior")
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

    // MARK: About

    private var about: some View {
        Section {
            LabeledContent("Version",
                           value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                .font(.nogMeta)
        } header: {
            SectionLabel(title: "About")
        } footer: {
            Text("Nog. Capture it, it nogs you until it's done.")
        }
        .listRowBackground(Theme.glass)
    }

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
                ForEach(NogProfile.allCases) { profile in
                    Button {
                        firstDelay = profile.firstDelayMinutes
                        repeatMinutes = profile.repeatMinutes
                        curve = profile.curve
                        profileEscalate = profile.escalateAfter ?? -1
                    } label: {
                        ProfileCard(profile: profile, isSelected: currentProfile == profile)
                    }
                    .buttonStyle(.plain)
                }
                DisclosureGroup(isExpanded: $showFineTune) {
                    Stepper(value: $firstDelay, in: 0...240, step: 1) {
                        LabeledContent("First nog", value: firstDelay == 0 ? "Right away" : "after \(IntervalFormat.amount(firstDelay))")
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
                } label: {
                    Text(currentProfile == nil ? "Fine-tune · Custom" : "Fine-tune")
                }
            } header: {
                SectionLabel(title: "Default profile")
            } footer: {
                Text("New captures use this profile unless you type one: !whisper, !easing, !relentless. Each item can switch profile on its own page.")
            }
            .listRowBackground(Theme.glass)

            Section {
                Toggle("Quiet hours", isOn: $quietEnabled)
                if quietEnabled {
                    TimeTunerRow(title: "From", minutes: $quietStart)
                    TimeTunerRow(title: "Until", minutes: $quietEnd)
                    Toggle("All weekend", isOn: $quietWeekends)
                }
            } header: {
                SectionLabel(title: "Quiet hours")
            } footer: {
                Text("Nothing nogs or rings during quiet hours. Anything due waits until they end.")
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
        .navigationTitle("Nogs & alerts")
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
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
        case .whisper: Theme.blue
        case .steady, .easing: Theme.violet
        case .relentless: Theme.pink
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
                SectionLabel(title: "▶︎ Nogitivity")
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
        .navigationTitle("Nogitivity")
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

private struct CaptureCheatSheet: View {
    var body: some View {
        List {
            Section {
                line("lunch next tues", "Lunch, Tuesday 12:00")
                line("call mom tomorrow at 3", "tomorrow 3 PM")
                line("dentist nov 12 at 2:30pm", "a date and time")
                line("stretch in 20 min", "relative time")
                line("pills every 4 hours", "sets the repeat")
            } header: {
                SectionLabel(title: "Plain English")
            }
            .listRowBackground(Theme.glass)
            Section {
                line("!8m  !2h  !1d", "repeat every 8 min / 2 h / 1 day")
                line("!once  !norepeat", "remind once, no repeat")
                line("!off", "no reminder (just an idea)")
                line("!log  !steady", "gaps double each time, or stay the same")
                line("!alarm", "ring like a real alarm")
                line("!whisper  !easing  !relentless", "use a nog profile")
                line("@30m  @2h  @now", "when to start nogging")
                line("~30m  ~2h", "how long it'll take (▶︎ timebox)")
                line("#tag", "add a tag")
            } header: {
                SectionLabel(title: "Tokens")
            }
            .listRowBackground(Theme.glass)
        }
        .nogListStyle()
        .navigationTitle("Capture shortcuts")
    }

    private func line(_ syntax: String, _ meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(syntax).font(.nogReadout(15))
            Text(meaning).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SiriPage: View {
    var body: some View {
        List {
            Section {
                phrase("Remind me in Nog to call mom tomorrow at 3")
                phrase("Add milk to my Groceries list in Nog")
                phrase("Mark this as done")
                phrase("Set the due date for this to Friday")
                phrase("Start write report in Nog")
                phrase("Nog me")
            } header: {
                SectionLabel(title: "Try saying")
            } footer: {
                Text("Any item with sub-items works as a list for Siri. Assign “Quick Capture” to the Action Button in iOS Settings → Action Button → Shortcut.")
            }
            .listRowBackground(Theme.glass)
        }
        .nogListStyle()
        .navigationTitle("Siri & Shortcuts")
    }

    private func phrase(_ text: String) -> some View {
        Label("“\(text)”", systemImage: "quote.bubble").foregroundStyle(.primary)
    }
}
