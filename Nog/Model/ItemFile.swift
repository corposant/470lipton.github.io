import Foundation

/// Each item is stored as a plain Markdown file with a small YAML-style header:
///
///     ---
///     id: 6F1C…
///     title: Call the dentist
///     status: open
///     created: 2026-11-05T18:00:00Z
///     updated: 2026-11-05T18:00:00Z
///     tags: [health, calls]
///     remind_at: 2026-11-05T18:15:00Z
///     repeat_minutes: 8
///     repeat_curve: logarithmic      (omitted when steady)
///     ---
///     Notes go here. Link to other items with [[Another item]].
enum ItemFile {
    static func encode(_ item: Item) -> String {
        var lines = ["---"]
        lines.append("id: \(item.id.uuidString)")
        lines.append("title: \(oneLine(item.title))")
        lines.append("status: \(item.status.rawValue)")
        lines.append("created: \(iso(item.created))")
        lines.append("updated: \(iso(item.updated))")
        if let completed = item.completed { lines.append("completed: \(iso(completed))") }
        if let parent = item.parentID { lines.append("parent: \(parent.uuidString)") }
        let tags = item.tags.map { oneLine($0).replacingOccurrences(of: ",", with: " ") }
            .filter { !$0.isEmpty }
        if !tags.isEmpty { lines.append("tags: [\(tags.joined(separator: ", "))]") }
        if let since = item.doingSince { lines.append("doing_since: \(iso(since))") }
        if let box = item.timeboxMinutes { lines.append("timebox_minutes: \(box)") }
        if let estimate = item.estimateMinutes { lines.append("estimate_minutes: \(estimate)") }
        if item.timeSpent > 0 { lines.append("time_spent: \(Int(item.timeSpent))") }
        if let r = item.reminder {
            lines.append("remind_at: \(iso(r.start))")
            if let m = r.repeatMinutes { lines.append("repeat_minutes: \(m)") }
            if r.curve != .steady { lines.append("repeat_curve: \(r.curve.rawValue)") }
            if r.alarm { lines.append("alarm: true") }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + item.body
    }

    static func decode(_ text: String) -> Item? {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") else { return nil }
        let afterOpen = text.dropFirst(4)

        let header: Substring
        let body: String
        if let close = afterOpen.range(of: "\n---\n") {
            header = afterOpen[..<close.lowerBound]
            body = String(afterOpen[close.upperBound...])
        } else if afterOpen.hasSuffix("\n---") {
            header = afterOpen.dropLast(4)
            body = ""
        } else {
            return nil
        }

        var fields: [String: String] = [:]
        for line in header.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let idString = fields["id"], let id = UUID(uuidString: idString) else { return nil }

        var item = Item(id: id, title: fields["title"] ?? "", body: body)
        item.status = fields["status"].flatMap(ItemStatus.init(rawValue:)) ?? .open
        item.created = fields["created"].flatMap(date) ?? .now
        item.updated = fields["updated"].flatMap(date) ?? item.created
        item.completed = fields["completed"].flatMap(date)
        item.parentID = fields["parent"].flatMap(UUID.init(uuidString:))
        if let raw = fields["tags"] {
            item.tags = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        item.doingSince = fields["doing_since"].flatMap(date)
        item.timeboxMinutes = fields["timebox_minutes"].flatMap { Int($0) }
        item.estimateMinutes = fields["estimate_minutes"].flatMap { Int($0) }
        item.timeSpent = fields["time_spent"].flatMap { TimeInterval($0) } ?? 0
        if let start = fields["remind_at"].flatMap(date) {
            let repeatMinutes = fields["repeat_minutes"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            let curve = fields["repeat_curve"].flatMap(RepeatCurve.init(rawValue:)) ?? .steady
            item.reminder = Reminder(start: start, repeatMinutes: repeatMinutes, curve: curve,
                                     alarm: fields["alarm"] == "true")
        }
        return item
    }

    // MARK: - Helpers

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso(_ date: Date) -> String { formatter.string(from: date) }
    private static func date(_ string: String) -> Date? {
        formatter.date(from: string) ?? plainFormatter.date(from: string)
    }
}
