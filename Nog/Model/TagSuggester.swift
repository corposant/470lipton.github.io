import Foundation

/// How often and how recently a tag has been used.
struct TagStat: Hashable {
    /// The spelling used most recently.
    var tag: String
    var count: Int
    var lastUsed: Date
}

/// Tag auto-complete: recent tags when nothing is typed yet, otherwise matches
/// (prefix matches first), ranked by how often and how recently each was used.
enum TagSuggester {
    /// One entry per tag, merged case-insensitively.
    static func stats<S: Sequence>(_ items: S) -> [TagStat] where S.Element == Item {
        var byKey: [String: TagStat] = [:]
        for item in items {
            let used = max(item.created, item.updated)
            for tag in item.tags {
                let key = tag.lowercased()
                if var stat = byKey[key] {
                    stat.count += 1
                    if used > stat.lastUsed {
                        stat.lastUsed = used
                        stat.tag = tag
                    }
                    byKey[key] = stat
                } else {
                    byKey[key] = TagStat(tag: tag, count: 1, lastUsed: used)
                }
            }
        }
        return Array(byKey.values)
    }

    /// Up to `limit` tags for what's typed so far (`query`, without "#"), leaving out `excluding`.
    static func suggest(_ query: String, from stats: [TagStat], excluding: Set<String> = [],
                        limit: Int = 8, now: Date = .now) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let skip = Set(excluding.map { $0.lowercased() })
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        func score(_ s: TagStat) -> Double {
            // Frecency: uses, fading with age (a week-old use counts half).
            let days = max(0, now.timeIntervalSince(s.lastUsed) / 86_400)
            return Double(s.count) / (1 + days / 7)
        }

        let ranked = stats
            .filter { !skip.contains($0.tag.lowercased()) }
            .compactMap { stat -> (stat: TagStat, tier: Int)? in
                if q.isEmpty { return (stat, 0) }
                guard let range = stat.tag.range(of: q, options: options) else { return nil }
                return (stat, range.lowerBound == stat.tag.startIndex ? 0 : 1)
            }
            .sorted {
                if $0.tier != $1.tier { return $0.tier < $1.tier }
                // Nothing typed: most recent first. Typing: best frecency first.
                if q.isEmpty, $0.stat.lastUsed != $1.stat.lastUsed { return $0.stat.lastUsed > $1.stat.lastUsed }
                let a = score($0.stat), b = score($1.stat)
                if a != b { return a > b }
                return $0.stat.tag.localizedCaseInsensitiveCompare($1.stat.tag) == .orderedAscending
            }
        return ranked.prefix(limit).map(\.stat.tag)
    }

    // MARK: Typing a #tag in free text

    /// The #tag being typed at the end of `text` (without "#"), or nil when the last word isn't one.
    static func typingTag(in text: String) -> String? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        let token = text[lastTokenStart(in: text)...]
        guard token.hasPrefix("#") else { return nil }
        return String(token.dropFirst())
    }

    /// Replaces the #tag being typed at the end of `text` with the full tag and a space.
    static func completing(_ text: String, with tag: String) -> String {
        guard typingTag(in: text) != nil else { return text }
        return String(text[..<lastTokenStart(in: text)]) + "#" + tag + " "
    }

    /// Tags already written in `text`, not counting the one still being typed.
    static func writtenTags(in text: String) -> Set<String> {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if typingTag(in: text) != nil, !words.isEmpty { words.removeLast() }
        return Set(words.filter { $0.hasPrefix("#") && $0.count > 1 }.map { String($0.dropFirst()).lowercased() })
    }

    private static func lastTokenStart(in text: String) -> String.Index {
        text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
    }
}
