import Foundation

/// A sub-nog's reminder names its parent, so "Call back" says what it's about:
/// "Call back (Get the oil changed)". Used for notification and alarm titles, which
/// arrive on their own with nothing around them.
///
/// A long parent title is shortened: by Apple Intelligence where the phone has it
/// (worked out ahead of time, see `ParentLabelCache`, because notifications are
/// scheduled long before they fire), otherwise cut at a word with "…".
enum ParentContext {
    /// Longest parent label kept whole. Past this the banner title gets hard to take in at a glance.
    static let maxLabelLength = 28

    /// The reminder title for every item that has one: its own title, plus "(parent)" for a sub-nog.
    /// `shortened` maps a long parent title to its Apple Intelligence label.
    static func titles(for items: [Item], shortened: [String: String] = [:]) -> [UUID: String] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var titles: [UUID: String] = [:]
        for item in items {
            let parent = item.parentID.flatMap { byID[$0]?.title }
            titles[item.id] = title(item.title, parent: parent, shortened: shortened)
        }
        return titles
    }

    /// "Call back (Get the oil changed)". Just the title when there's no parent, the parent
    /// title is empty, or the title already says it ("Book oil change" under "Oil change").
    static func title(_ title: String, parent: String?, shortened: [String: String] = [:]) -> String {
        guard let parent else { return title }
        let label = self.label(for: parent, shortened: shortened)
        guard !label.isEmpty else { return title }
        let key = { (s: String) in s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespaces)) }
        let parentKey = key(label)
        if parentKey.count >= 3, title.lowercased().contains(parentKey) { return title }
        return "\(title) (\(label))"
    }

    /// The parent's title as it goes in the brackets: whole when short, else the Apple
    /// Intelligence label when there is a usable one, else cut at a word.
    static func label(for parent: String, shortened: [String: String] = [:]) -> String {
        let clean = tidy(parent)
        guard needsShortening(clean) else { return clean }
        if let short = shortened[clean].map(tidy), !short.isEmpty, short.count <= maxLabelLength {
            return short
        }
        return truncated(clean)
    }

    static func needsShortening(_ parent: String) -> Bool {
        tidy(parent).count > maxLabelLength
    }

    /// Long parent titles in use, the ones worth asking Apple Intelligence about.
    static func longParentTitles(in items: [Item]) -> Set<String> {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Set(items.compactMap { item in
            item.parentID.flatMap { byID[$0]?.title }.map(tidy)
        }.filter(needsShortening))
    }

    /// Cuts at the last whole word that fits and adds "…": "Sort out the car before the trip…".
    static func truncated(_ s: String, to limit: Int = maxLabelLength) -> String {
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit - 1))
        var cut = head
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= limit / 2 {
            cut = String(head[..<space])
        }
        cut = cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return cut + "…"
    }

    /// One line, single spaces, no trailing full stop.
    static func tidy(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
    }
}
