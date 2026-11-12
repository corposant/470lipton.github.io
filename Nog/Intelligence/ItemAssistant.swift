import Foundation
import FoundationModels
import SwiftUI

/// On-device Apple Intelligence helpers. Nothing leaves the phone.
enum ItemAssistant {
    @Generable
    struct Breakdown {
        @Guide(description: "Between 2 and 5 next physical steps, in the order they'd happen. Each is one action a person does with their hands, voice or feet, starts with a verb, and is under 7 words.")
        var steps: [String]
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// The angle for every suggestion: what is the very next, simplest physical thing to do?
    /// The examples teach the model to read the exact wording. "Get the oil changed" means
    /// someone else does it, so the steps are about arranging that; "do the oil change" means
    /// you do it, so the steps are about getting the parts.
    static let breakdownInstructions = """
        You help someone who struggles to get started. Answer one question: \
        what are the next, simplest physical steps toward this? \
        Think very, very simple. Each step is one concrete action someone could do right now \
        with their hands, voice or feet: call, text, open, find, buy, put, write, walk to. \
        No planning, thinking or deciding steps. No advice. \
        Read the exact wording, because it changes who does the work. \
        "Get it done", "get it fixed" or "book" means someone else does it, so the steps are about arranging that. \
        "Do it" or "fix it" means the person does it, so the steps are about getting what they need and starting. \
        Use the specific things the item names. Keep the person's words where you can. \
        Each step must be small enough to start in two minutes; the very first should be the \
        easiest thing to physically begin (open, pick up, find, put on). \
        Stop at the first few steps, not the whole job. Never repeat steps they already have.

        Example: "Get the oil changed" -> Find a service shop nearby; Call to book an appointment
        Example: "Do the oil change" -> Check for sales on oil; Buy an oil filter and crush washer; \
        Buy 6 litres of 0W-20 oil
        Example: "Clean the kitchen" -> Put dishes in the sink; Wipe the counters; Take out the trash
        Example: "Write the report" -> Open the laptop; Open a blank document; Type the report's title
        Example: "Renew passport" -> Find the renewal form online; Print the form; Get a passport photo taken
        """

    /// Turns a nog into its next few simple, physical steps.
    static func breakDown(_ item: Item, existing: [String]) async throws -> [String] {
        let session = LanguageModelSession(instructions: breakdownInstructions)
        var prompt = "Item: \(item.title)"
        if !item.body.isEmpty { prompt += "\nNotes: \(item.body.prefix(1500))" }
        if !existing.isEmpty { prompt += "\nSteps they already have: \(existing.joined(separator: "; "))" }
        let response = try await session.respond(to: prompt, generating: Breakdown.self)
        let existingKeys = Set(existing.map(normalized))
        var seen = Set<String>()
        return response.content.steps
            .map(cleaned)
            .filter { !$0.isEmpty }
            // The model sometimes echoes a step they already have, or the same step twice.
            .filter { !existingKeys.contains(normalized($0)) && seen.insert(normalized($0)).inserted }
    }

    @Generable
    struct ShortLabel {
        @Guide(description: "The same task in 2 to 4 words, using the person's own words. No full stop.")
        var label: String
    }

    static let shortLabelInstructions = """
        You shorten a to-do title into a tiny label that goes in brackets after one of its steps, \
        so a reminder like "Call back" says what it's about. \
        Use 2 to 4 words. Keep the person's own words, and keep the thing it is about. \
        Drop dates, times, filler and explanations. Never add anything that isn't there.

        Example: "Get the oil changed before the road trip next month" -> Oil change
        Example: "Sort out the kitchen renovation budget with Sam" -> Kitchen reno budget
        Example: "Renew my passport so I can go to the wedding in June" -> Renew passport
        """

    /// A long nog title cut down for a sub-nog's reminder: "Oil change". nil when it isn't usable.
    static func shortLabel(for title: String) async throws -> String? {
        let session = LanguageModelSession(instructions: shortLabelInstructions)
        let response = try await session.respond(to: "Title: \(title.prefix(500))", generating: ShortLabel.self)
        let label = ParentContext.tidy(cleaned(response.content.label))
        guard !label.isEmpty, label.count <= ParentContext.maxLabelLength, label.count < title.count else { return nil }
        return label
    }

    /// Trims spaces, list numbering ("1.", "2 -", "•") and a trailing full stop.
    static func cleaned(_ step: String) -> String {
        var s = step.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: #"^(\d+[.):]|\d+\s*-\s|[-•*])\s*"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        while s.hasSuffix(".") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ step: String) -> String {
        cleaned(step).lowercased()
    }
}

/// Sheet: suggests sub-items, you pick which to keep.
struct BreakdownSheet: View {
    @Environment(ItemStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var steps: [String] = []
    @State private var selected = Set<String>()
    @State private var error: String?
    @State private var isThinking = true

    var body: some View {
        NavigationStack {
            List {
                if isThinking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Finding the next steps…").foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(steps, id: \.self) { step in
                            Button {
                                if selected.contains(step) { selected.remove(step) } else { selected.insert(step) }
                            } label: {
                                Label {
                                    Text(step).foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: selected.contains(step) ? "checkmark.circle" : "circle")
                                        .foregroundStyle(selected.contains(step) ? Theme.violet : Theme.muted)
                                }
                            }
                        }
                    } footer: {
                        Text("Added as quiet sub-nogs.")
                    }
                }
            }
            .nogListStyle()
            .navigationTitle("Next steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") {
                        for step in steps where selected.contains(step) {
                            store.capture("\(step) !off", parent: item.id)
                        }
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            let existing = store.children(of: item.id).map(\.title)
            steps = try await ItemAssistant.breakDown(item, existing: existing)
            selected = Set(steps)
        } catch {
            self.error = "Apple Intelligence couldn't help with this one right now."
        }
        isThinking = false
    }
}
