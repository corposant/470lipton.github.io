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
                Text("iCloud isn't available. Check you're signed in and iCloud Drive is on for Nog. Items stay on this iPhone until it is.")
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
                NogDefaultsPage()
            } label: {
                row("Nog defaults", "bell.badge", Theme.pink,
                    detail: repeatMinutes > 0 ? "every \(IntervalFormat.short(repeatMinutes))" : "once")
            }
            NavigationLink {
                DoingPage()
            } label: {
                row("Doing", "play.circle", Theme.blue,
                    detail: timebox > 0 ? "\(IntervalFormat.short(timebox)) box" : "open-ended")
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
                row("Alerts & permissions", "checkmark.shield", Theme.blue, detail: nil)
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

private struct NogDefaultsPage: View {
    @AppStorage(NogSettings.firstDelayKey) private var firstDelay = NogSettings.defaultFirstDelay
    @AppStorage(NogSettings.repeatKey) private var repeatMinutes = NogSettings.defaultRepeat
    @AppStorage(NogSettings.curveKey) private var curve: RepeatCurve = .steady

    var body: some View {
        List {
            Section {
                Stepper(value: $firstDelay, in: 0...240, step: 5) {
                    LabeledContent("First nog", value: firstDelay == 0 ? "Right away" : "after \(IntervalFormat.short(firstDelay))")
                }
                Picker("Then", selection: $repeatMinutes) {
                    ForEach(NogSettings.repeatChoices, id: \.self) { Text(NogSettings.repeatLabel($0)).tag($0) }
                }
                if repeatMinutes > 0 {
                    Picker("Style", selection: $curve) {
                        ForEach(RepeatCurve.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                SectionLabel(title: "New captures")
            } footer: {
                Text(curve == .logarithmic && repeatMinutes > 0
                     ? "Logarithmic: the gap doubles after each nog until it reaches a day, then nogs daily until done."
                     : "Every captured item gets this unless you type an override.")
            }
            .listRowBackground(Theme.glass)
        }
        .nogListStyle()
        .navigationTitle("Nog defaults")
    }
}

private struct DoingPage: View {
    @AppStorage(NogSettings.timeboxKey) private var timebox = NogSettings.defaultTimebox

    var body: some View {
        List {
            Section {
                Picker("Default timebox", selection: $timebox) {
                    Text("Open-ended").tag(0)
                    ForEach(NogSettings.timeboxChoices, id: \.self) { Text(IntervalFormat.short($0)).tag($0) }
                }
            } header: {
                SectionLabel(title: "▶︎ Doing")
            } footer: {
                Text("Nog suggests, in order: the item's estimate, how long similar items took you (same #tag or project), a short box if it's urgent or overdue, then this default.")
            }
            .listRowBackground(Theme.glass)
        }
        .nogListStyle()
        .navigationTitle("Doing")
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
        .navigationTitle("Alerts & permissions")
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
                line("!once", "remind once")
                line("!off", "no reminder (just an idea)")
                line("!log  !steady", "gaps double each time, or stay the same")
                line("!alarm", "ring like a real alarm")
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
