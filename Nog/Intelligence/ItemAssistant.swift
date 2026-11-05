import Foundation
import FoundationModels
import SwiftUI

/// On-device Apple Intelligence helpers. Nothing leaves the phone.
enum ItemAssistant {
    @Generable
    struct Breakdown {
        @Guide(description: "Between 3 and 7 small, concrete next steps, in order. Each starts with a verb and is under 8 words.")
        var steps: [String]
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Turns a to-do, idea or project into small first steps.
    static func breakDown(_ item: Item, existing: [String]) async throws -> [String] {
        let session = LanguageModelSession(instructions: """
            You help someone get started on things they keep putting off. \
            Break the item into small, concrete, doable steps. Keep the person's wording where you can. \
            Never repeat steps they already have.
            """)
        var prompt = "Item: \(item.title)"
        if !item.body.isEmpty { prompt += "\nNotes: \(item.body.prefix(1500))" }
        if !existing.isEmpty { prompt += "\nSteps they already have: \(existing.joined(separator: "; "))" }
        let response = try await session.respond(to: prompt, generating: Breakdown.self)
        return response.content.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
                        Text("Breaking it down…").foregroundStyle(.secondary)
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
                        Text("Added as sub-items without their own nogs. \(item.title) keeps nogging you.")
                    }
                }
            }
            .nogListStyle()
            .navigationTitle("Break it down")
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
