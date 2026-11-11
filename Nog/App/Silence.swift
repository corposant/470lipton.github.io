import SwiftUI
import UIKit

/// Silencing every nog and alarm for a while (or until turned back on), from the app
/// icon's long-press menu, the Silence sheet, or Settings. Nogs due while silenced come
/// once it ends; repeating ones carry on from there.
@MainActor
enum Silence {
    /// Lengths offered, in minutes.
    static let durations = [60, 120, 300, 720]

    static var until: Date? { NogSettings.silencedUntil }

    /// Silence for `minutes`, or until turned back on (nil).
    static func silence(for minutes: Int?) {
        NogSettings.silencedUntil = minutes.map { .now.addingTimeInterval(TimeInterval($0 * 60)) } ?? .distantFuture
        apply()
    }

    static func silence(until date: Date) {
        NogSettings.silencedUntil = date
        apply()
    }

    static func resume() {
        NogSettings.silencedUntil = nil
        apply()
    }

    private static func apply() {
        QuickActions.update()
        Task { await ItemStore.shared.syncNow() }
    }

    static func label(minutes: Int) -> String {
        "Silence for \(IntervalFormat.amount(minutes))"
    }
}

/// The app icon's long-press menu (Home Screen quick actions).
@MainActor
enum QuickActions {
    enum Kind: String {
        case toggle = "nog.silence.toggle"
        case hour1 = "nog.silence.60"
        case hour2 = "nog.silence.120"
        case more = "nog.silence.more"
    }

    /// Rebuilds the menu so its top item reads Silence or Resume, with the current end time.
    static func update() {
        var items: [UIApplicationShortcutItem] = []
        if let until = Silence.until {
            items.append(UIApplicationShortcutItem(
                type: Kind.toggle.rawValue, localizedTitle: "Resume nogs",
                localizedSubtitle: NogSettings.silenceLabel(until),
                icon: UIApplicationShortcutIcon(systemImageName: "bell")))
        } else {
            items.append(UIApplicationShortcutItem(
                type: Kind.toggle.rawValue, localizedTitle: "Silence nogs",
                localizedSubtitle: "Until you turn them back on",
                icon: UIApplicationShortcutIcon(systemImageName: "bell.slash")))
        }
        items.append(UIApplicationShortcutItem(
            type: Kind.hour1.rawValue, localizedTitle: Silence.label(minutes: 60), localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "moon.zzz")))
        items.append(UIApplicationShortcutItem(
            type: Kind.hour2.rawValue, localizedTitle: Silence.label(minutes: 120), localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "moon.zzz")))
        items.append(UIApplicationShortcutItem(
            type: Kind.more.rawValue, localizedTitle: "Silence for…",
            localizedSubtitle: "5 hours, 12 hours, until morning",
            icon: UIApplicationShortcutIcon(systemImageName: "clock.badge")))
        UIApplication.shared.shortcutItems = items
    }

    /// Runs a tapped quick action. Returns false for one this version doesn't know.
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        switch Kind(rawValue: item.type) {
        case .toggle:
            if Silence.until != nil { Silence.resume() } else { Silence.silence(for: nil) }
        case .hour1:
            Silence.silence(for: 60)
        case .hour2:
            Silence.silence(for: 120)
        case .more:
            Router.shared.showSilenceSheet = true
        case nil:
            return false
        }
        return true
    }
}

/// Receives quick actions while the app is running (a cold launch is handled in the app delegate).
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            completionHandler(QuickActions.handle(shortcutItem))
        }
    }
}

// MARK: - Views

/// Choose how long to silence nogs and alarms.
struct SilenceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NogSettings.silencedUntilKey) private var stored: Double = 0

    var body: some View {
        let until = stored == 0 ? nil : Date(timeIntervalSinceReferenceDate: stored)
        let morning = NogSettings.nextMorning()
        NavigationStack {
            List {
                if let until, until > .now {
                    Section {
                        Label(NogSettings.silenceLabel(until), systemImage: "bell.slash.fill")
                            .foregroundStyle(Theme.pink)
                        Button {
                            Silence.resume()
                            dismiss()
                        } label: {
                            Label("Resume nogs now", systemImage: "bell")
                        }
                    }
                    .listRowBackground(Theme.glass)
                }
                Section {
                    ForEach(Silence.durations, id: \.self) { minutes in
                        Button {
                            Silence.silence(for: minutes)
                            dismiss()
                        } label: {
                            Label(Silence.label(minutes: minutes), systemImage: "moon.zzz")
                        }
                    }
                    Button {
                        Silence.silence(until: NogSettings.nextMorning())
                        dismiss()
                    } label: {
                        Label((Calendar.current.isDateInTomorrow(morning) ? "Until tomorrow " : "Until ")
                              + morning.formatted(date: .omitted, time: .shortened),
                              systemImage: "sunrise")
                    }
                    Button {
                        Silence.silence(for: nil)
                        dismiss()
                    } label: {
                        Label("Until I turn them back on", systemImage: "bell.slash")
                    }
                } header: {
                    SectionLabel(title: "Silence nogs and alarms")
                } footer: {
                    Text("Anything due comes when silence ends.")
                }
                .listRowBackground(Theme.glass)
            }
            .nogListStyle()
            .navigationTitle("Silence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .tint(Theme.pink)
        .presentationDetents([.medium, .large])
    }
}

/// "Nogs silenced until 5:30 PM · Resume", shown at the top of the lists while silenced.
struct SilenceBanner: View {
    /// Read so the banner updates when silence changes anywhere.
    @AppStorage(NogSettings.silencedUntilKey) private var stored: Double = 0

    var body: some View {
        // Re-check each minute so it disappears when silence runs out.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let until = stored == 0 ? nil : Date(timeIntervalSinceReferenceDate: stored)
            if let until, until > context.date {
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(Theme.pink)
                    Text(NogSettings.silenceLabel(until, now: context.date))
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Resume") { Silence.resume() }
                        .buttonStyle(OutlineButtonStyle(tint: Theme.pink, expands: false))
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
