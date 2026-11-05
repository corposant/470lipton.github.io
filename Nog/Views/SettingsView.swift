import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NogSettings.firstDelayKey) private var firstDelay = NogSettings.defaultFirstDelay
    @AppStorage(NogSettings.repeatKey) private var repeatMinutes = NogSettings.defaultRepeat
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var pending = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $firstDelay, in: 0...240, step: 5) {
                        LabeledContent("First nog", value: firstDelay == 0 ? "Right away" : "after \(IntervalFormat.short(firstDelay))")
                    }
                    Picker("Then", selection: $repeatMinutes) {
                        ForEach(NogSettings.repeatChoices, id: \.self) { Text(NogSettings.repeatLabel($0)).tag($0) }
                    }
                } header: {
                    Text("Default for new captures")
                } footer: {
                    Text("Every captured item gets this unless you type an override.")
                }

                Section("Capture shortcuts") {
                    shortcut("!8m  !2h  !1d", "repeat every 8 min / 2 h / 1 day")
                    shortcut("!once", "remind once, don't repeat")
                    shortcut("!off", "no reminder (just an idea)")
                    shortcut("@30m  @2h  @now", "when to start nogging")
                    shortcut("#tag", "add a tag")
                }

                Section("Notifications") {
                    LabeledContent("Permission", value: label(for: authorization))
                    LabeledContent("Scheduled right now", value: "\(pending)")
                    Button("Re-sync reminders") {
                        Task {
                            await store.syncNow()
                            await refresh()
                        }
                    }
                    if authorization == .denied {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                Section {
                    Text("Files app → On My iPhone → Nog → Items")
                        .font(.footnote)
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Every item is a plain Markdown file.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        authorization = await NotificationScheduler.shared.authorizationStatus()
        pending = await NotificationScheduler.shared.pendingCount()
    }

    private func shortcut(_ syntax: String, _ meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(syntax).font(.body.monospaced())
            Text(meaning).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied — nogs won't show"
        case .provisional: return "Quiet (provisional)"
        case .ephemeral: return "Temporary"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }
}
