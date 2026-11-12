import Foundation

/// Apple Intelligence's short labels for long parent titles ("Oil change" for "Get the oil
/// changed before the road trip next month"), kept so each title is only shortened once.
///
/// Notifications are scheduled ahead of time, so the label has to exist before the nog is
/// lined up. Each sync shortens a few new titles; until a label is ready (or on a phone
/// without Apple Intelligence) the title is cut at a word instead (`ParentContext.truncated`).
@MainActor
enum ParentLabelCache {
    private static let key = "parentShortLabels"
    /// New titles shortened per sync, so a first launch with lots of projects stays quick.
    static let perSync = 3

    /// Titles the model threw on in this launch (busy, still downloading, a guardrail).
    /// Not asked again until the app is next launched, so a title the model always refuses
    /// doesn't cost a model call on every sync.
    private static var failed: Set<String> = []

    static var labels: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// The labels already worked out for these items' long parent titles. Instant: no model call.
    static func current(for items: [Item]) -> [String: String] {
        let wanted = ParentContext.longParentTitles(in: items)
        return labels.filter { wanted.contains($0.key) }
    }

    /// Shortens up to `perSync` long parent titles that don't have a label yet, drops labels
    /// for titles no longer in use, and returns the labels to plan with.
    static func refresh(items: [Item]) async -> [String: String] {
        let wanted = ParentContext.longParentTitles(in: items)
        var stored = labels.filter { wanted.contains($0.key) }
        // Titles shown as "Nog" on the Lock Screen don't need labels; don't spend the model on them.
        if NogSettings.showTitles, ItemAssistant.isAvailable {
            for title in wanted.subtracting(stored.keys).subtracting(failed).sorted().prefix(perSync) {
                // An error leaves it cut at a word, and it's tried again next launch. An unusable
                // answer is remembered as "" (cut at a word) so it isn't asked every time.
                do { stored[title] = try await ItemAssistant.shortLabel(for: title) ?? "" } catch { failed.insert(title) }
            }
        }
        if stored != labels { UserDefaults.standard.set(stored, forKey: key) }
        return stored
    }
}
