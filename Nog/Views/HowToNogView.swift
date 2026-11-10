import SwiftUI

/// "How to Nog": everything the New Nog field understands, as a standard grouped list.
/// Every example here must parse as described (see `CaptureParser`, `NaturalDateParser`,
/// `NogProfile.token`). Opened from the New Nog screen and from Settings.
struct HowToNogView: View {
    var body: some View {
        List {
            section("When", footer: "Plain English works anywhere in the line.", [
                ("lunch next tues", "Tuesday at 12:00"),
                ("call mom tomorrow at 3", "tomorrow, 3 PM"),
                ("dentist nov 12 at 2:30pm", "a date and time"),
                ("standup tomorrow morning", "tomorrow, 9 AM"),
                ("report by eod", "end of today"),
                ("stretch in 20 min", "20 minutes from now"),
                ("@30m  @2h  @1d  @now", "start nogging after 30 min, 2 h, a day, or now"),
            ])
            section("How often", [
                ("pills every 4 hours", "nogs every 4 hours"),
                ("water plants hourly", "every hour (or daily, weekly)"),
                ("!8m  !2h  !1d", "repeat every 8 min, 2 h, a day"),
                ("!once", "remind once, no repeat"),
                ("!log", "gaps double each time: 8, 16, 32 min…"),
                ("!off", "no reminder, just keep the idea"),
            ])
            section("How it gets you", footer: "Start typing a ! word and Nog offers to finish it.", [
                ("!hush  !hus", "silent banner every 15 min, never rings"),
                ("!whisper  !whi", "gentle, never rings"),
                ("!daily  !dai", "once a day at the same time, never rings"),
                ("!easing  !eas", "eases off over time"),
                ("!steady  !ste", "every 8 min until done"),
                ("!building  !bui", "heads-up 15, 5, 1 min before, then closer and closer"),
                ("!hyperfocus  !hyp  !break", "every 5 min, rings after 1 ignored nog"),
                ("!unhinged  !unh", "no let-up, rings after 3 ignored nogs"),
                ("!alarm", "rings like a real alarm"),
            ])
            section("Tags", [
                ("call mom #family", "adds the tag family"),
                ("taxes #money #admin", "as many tags as you like"),
            ])
            section("Timebox", [
                ("~30m  ~2h", "how long it'll take, for the ▶︎ timebox"),
            ])
            section("Mix them", [
                ("pay rent fri 9am !1d #money ~10m", "“pay rent”, Friday 9 AM, daily, #money, 10 min"),
            ])
        }
        .nogListStyle()
        .navigationTitle("How to Nog")
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
