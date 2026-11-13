import Foundation

/// Apple Intelligence's short names for long steps on the Start button ("Check roof damage"
/// for "Check for structural damage on the north side of the roof"), kept so each step is
/// only shortened once. Until one is ready, or without Apple Intelligence, the step is cut
/// at a word instead (`StartButton.short`).
@MainActor
enum StepLabelCache {
    private static let key = "stepShortLabels"
    /// Kept to the most recent few, so the store doesn't grow forever.
    private static let capacity = 200
    /// Steps the model threw on in this launch; not asked again until the next launch.
    private static var failed: Set<String> = []

    private static var labels: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// The short name already worked out for this step, if any. "" means the model's answer
    /// wasn't usable, so it's cut at a word.
    static func label(for step: String) -> String? { labels[step] }

    /// Asks Apple Intelligence for a short name, once per step. Returns nil if it can't help.
    static func shorten(_ step: String, limit: Int) async -> String? {
        if let known = labels[step] { return known.isEmpty ? nil : known }
        guard ItemAssistant.isAvailable, !failed.contains(step) else { return nil }
        do {
            let short = try await ItemAssistant.shortStep(for: step, limit: limit)
            var stored = labels
            if stored.count >= capacity { stored.removeAll() }
            stored[step] = short ?? ""
            UserDefaults.standard.set(stored, forKey: key)
            return short
        } catch {
            failed.insert(step)
            return nil
        }
    }
}
