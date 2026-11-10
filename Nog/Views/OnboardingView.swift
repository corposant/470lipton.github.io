import SwiftUI
import UserNotifications

/// First run: what Nog does, how firm it should be, and the permissions it needs,
/// each with the reason it's asked for. Three short steps, Back and Next on every one,
/// nothing hidden behind a swipe. Shown once; existing installs skip it.
struct OnboardingView: View {
    static let doneKey = "onboardingDone"

    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(OnboardingView.doneKey) private var done = false
    @AppStorage(Calm.lowStimulationKey) private var lowStimulation = false
    @State private var step = 0
    @State private var profile: NogProfile = NogSettings.defaultProfile ?? .steady
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var alarmsAllowed = AlarmScheduler.shared.isAuthorized

    private let steps = 3

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Step \(step + 1) of \(steps)")
                        .font(.nogMeta)
                        .foregroundStyle(Theme.muted)
                    switch step {
                    case 0: welcome
                    case 1: firmness
                    default: permissions
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            buttons
        }
        .background { NogBackground() }
        .task { notifications = await NotificationScheduler.shared.authorizationStatus() }
        .nogAnimation(.snappy, value: step)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nog reminds you until it's done")
                .font(.nogTitle(30))
                .accessibilityAddTraits(.isHeader)
            Text("This is an unhinged reminder app on steroids. If your brain needs something this strong: I'm sorry, and I hope you enjoy it.")
                .font(.title3)
                .foregroundStyle(.secondary)
            point("square.and.pencil", "Type it the way you'd say it",
                  "“Call mom tomorrow at 3” or “meds every morning”. Nog works out the when.")
            point("bell.badge", "It keeps reminding you",
                  "Not just once. Nog reminds you again and again until you tap Done or Snooze.")
            point("repeat", "Routines come back",
                  "Things you do again and again, like meds or bins, come back after you tap Done.")
            point("hand.raised", "You stay in charge",
                  "Snooze anything, set quiet hours, or silence everything for a while.")
        }
    }

    private var firmness: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How firm should Nog be?")
                .font(.nogTitle(30))
                .accessibilityAddTraits(.isHeader)
            Text("This is the starting point for everything you add. You can change it any time, or for one item.")
                .foregroundStyle(.secondary)
            ForEach(NogProfile.onboardingChoices) { choice in
                Button {
                    profile = choice
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: profile == choice ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(profile == choice ? Theme.pink : Theme.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.plainName).font(.headline)
                            Text(choice.summary).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(profile == choice ? Theme.pink : Theme.edgeStrong, lineWidth: profile == choice ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(profile == choice ? .isSelected : [])
            }
            Toggle(isOn: $lowStimulation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Low stimulation")
                    Text("No glow, motion or vibration.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.blue)
            .padding(14)
            .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let Nog reach you")
                .font(.nogTitle(30))
                .accessibilityAddTraits(.isHeader)
            Text("iOS asks once for each. You can change your mind later in the Settings app.")
                .foregroundStyle(.secondary)

            permissionCard(
                icon: "bell.badge", title: "Notifications", required: true,
                why: "This is how Nog reminds you. Without it, nothing can reach you.",
                granted: notifications == .authorized || notifications == .provisional,
                denied: notifications == .denied) {
                    Task {
                        await NotificationScheduler.shared.requestAuthorization()
                        notifications = await NotificationScheduler.shared.authorizationStatus()
                    }
                }

            permissionCard(
                icon: "alarm", title: "Alarms (optional)", required: false,
                why: "For the things you really can't miss. An alarm rings through Silent mode and Focus, like the Clock app. Nog only uses it when you ask.",
                granted: alarmsAllowed, denied: false) {
                    Task { alarmsAllowed = await AlarmScheduler.shared.requestAuthorization() }
                }

            Text("Tip: to let reminders through Focus too, turn on Time Sensitive in the Settings app under Notifications › Nog.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(Theme.pink)
                .frame(minWidth: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func permissionCard(icon: String, title: String, required: Bool, why: String,
                                granted: Bool, denied: Bool, ask: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            Text(why).font(.subheadline).foregroundStyle(.secondary)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle")
                    .foregroundStyle(StatusDial.tint(.done))
                    .font(.subheadline.weight(.semibold))
            } else if denied {
                Text("Turned off. You can allow it in the Settings app under Notifications › Nog.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.pink)
            } else {
                Button(required ? "Allow notifications" : "Allow alarms", action: ask)
                    .buttonStyle(OutlineButtonStyle(tint: required ? Theme.pink : Theme.violet))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var buttons: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(OutlineButtonStyle(tint: Theme.muted))
            }
            Button(step == steps - 1 ? "START" : "NEXT") { next() }
                .buttonStyle(GradientOutlineButtonStyle())
                .accessibilityLabel(step == steps - 1 ? "Start using Nog" : "Next")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func next() {
        if step == 1 { NogSettings.setDefaultProfile(profile) }
        if step < steps - 1 {
            step += 1
        } else {
            done = true
        }
    }
}

extension NogProfile {
    /// The three offered on first run: gentle, the default, and firm.
    static let onboardingChoices: [NogProfile] = [.whisper, .steady, .unhinged]

    /// What a newcomer would call it.
    var plainName: String {
        switch self {
        case .whisper: "Gentle"
        case .steady: "Steady (recommended)"
        case .unhinged: "Relentless"
        default: label
        }
    }
}
