import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NogSettings.firstDelayKey) private var firstDelay = NogSettings.defaultFirstDelay
    @AppStorage(NogSettings.repeatKey) private var repeatMinutes = NogSettings.defaultRepeat
    @AppStorage(NogSettings.curveKey) private var curve: RepeatCurve = .steady
    @AppStorage(NogSettings.timeboxKey) private var timebox = NogSettings.defaultTimebox
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
                    if repeatMinutes > 0 {
                        Picker("Style", selection: $curve) {
                            ForEach(RepeatCurve.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Default for new captures")
                } footer: {
                    Text(curve == .logarithmic && repeatMinutes > 0
                         ? "Logarithmic: the gap doubles after each nog (\(Self.example(repeatMinutes))…) until it reaches a day, then nogs daily until done."
                         : "Every captured item gets this unless you type an override.")
                }

                Section {
                    Picker("Default timebox", selection: $timebox) {
                        Text("Open-ended").tag(0)
                        ForEach(NogSettings.timeboxChoices, id: \.self) { Text(IntervalFormat.short($0)).tag($0) }
                    }
                } header: {
                    Text("▶︎ Doing")
                } footer: {
                    Text("Nog first suggests your estimate for the item, then how long similar items took you (same #tag or same project), then a short timebox if it's urgent or overdue. Otherwise it uses this default.")
                }

                Section("Capture shortcuts") {
                    shortcut("!8m  !2h  !1d", "repeat every 8 min / 2 h / 1 day")
                    shortcut("!once", "remind once, don't repeat")
                    shortcut("!log  !steady", "gaps double each time, or stay the same")
                    shortcut("!alarm", "ring like a real alarm, through Silent and Focus")
                    shortcut("~30m  ~2h", "how long it'll take (the ▶︎ timebox)")
                    shortcut("!off", "no reminder (just an idea)")
                    shortcut("@30m  @2h  @now", "when to start nogging")
                    shortcut("#tag", "add a tag")
                    shortcut("lunch next tues", "plain English works too")
                    shortcut("call mom tomorrow at 3", "day + time")
                    shortcut("pills every 4 hours", "sets the repeat")
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
                    if store.isUsingICloud {
                        Label("Syncing with iCloud Drive", systemImage: "icloud")
                        Text("iCloud Drive → Nog → Items").font(.footnote)
                    } else {
                        Label("On this iPhone only", systemImage: "iphone")
                        Text("Files app → On My iPhone → Nog → Items").font(.footnote)
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text(store.isUsingICloud
                         ? "Every item is a plain Markdown file, also visible on your Mac in iCloud Drive."
                         : "iCloud isn't available — check you're signed in and iCloud Drive is on. Items will move to iCloud automatically once it is.")
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

    static func example(_ base: Int) -> String {
        var gaps: [String] = []
        var m = base
        while gaps.count < 4 && m < Reminder.logarithmicCapMinutes {
            gaps.append(IntervalFormat.short(m))
            m *= 2
        }
        return gaps.joined(separator: ", ")
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
