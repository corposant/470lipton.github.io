import SwiftUI

/// "How to use Nog": everything the New Nog field understands, as a standard grouped list.
/// Every example here must parse as described (see `CaptureParser`, `NaturalDateParser`,
/// `NogProfile.token`). Opened from the New Nog screen and from Settings.
struct HowToNogView: View {
    var body: some View {
        List {
            section("When", [
                ("lunch next tues", "Tuesday at 12:00"),
                ("call mom tomorrow at 3", "tomorrow, 3 PM"),
                ("dentist nov 12 at 2:30pm", "a date and time"),
                ("standup tomorrow morning", "tomorrow, 9 AM"),
                ("report by eod", "end of today"),
                ("stretch in 20 min", "20 minutes from now"),
            ])
            section("Things that come back", footer: "Done moves it to next time.", [
                ("meds every morning", "every day at 9 AM"),
                ("bins every tue", "every Tuesday"),
                ("gym every mon and thu at 6pm", "two days a week"),
                ("standup every weekday at 9:30am", "Monday to Friday"),
                ("rent every month on the 1st", "monthly"),
                ("water plants every 2 days", "every other day"),
            ])
            section("Where", footer: "Save places first in Settings › Places.", [
                ("bins when I get home", "when you arrive home"),
                ("buy milk when I leave work", "when you leave work"),
                ("return book when I'm at the library", "any saved place"),
            ])
            section("How often until it's done", [
                ("pills every 4 hours", "reminds you every 4 hours"),
                ("check oven every 10 min", "every 10 minutes"),
            ])
            section("Tags", [
                ("call mom #family", "adds the tag family"),
                ("taxes #money #admin", "as many as you like"),
            ])
            section("Links", [
                ("[[Call mom]]", "in notes, links to that nog"),
            ])
            section("Shortcuts (optional)", footer: "Type ! for suggestions.", [
                ("@30m  @2h  @1d  @now", "start in 30 min, 2 h, a day, or now"),
                ("!8m  !2h  !1d", "every 8 min, 2 h, a day"),
                ("!once", "once, no repeat"),
                ("!off", "no reminder"),
                ("!alarm", "rings like an alarm"),
                ("!whisper  !steady  !building  !unhinged", "a style (three letters will do)"),
                ("!hush  !teatime  !daily  !easing", "more styles"),
                ("~30m  ~2h", "how long it'll take"),
            ])
        }
        .nogListStyle()
        .navigationTitle("How to use Nog")
    }

    private func section(_ title: String, footer: String? = nil,
                         _ examples: [(syntax: String, meaning: String)]) -> some View {
        Section {
            ForEach(examples, id: \.syntax) { example in
                VStack(alignment: .leading, spacing: 3) {
                    Text(example.syntax).nogReadout(15)
                    Text(example.meaning).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            SectionLabel(title: title)
        } footer: {
            if let footer { Text(footer) }
        }
        .listRowBackground(Theme.glass)
    }
}

/// The same guide as a sheet, with Done, for the New Nog screen.
struct HowToNogSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HowToNogView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}
