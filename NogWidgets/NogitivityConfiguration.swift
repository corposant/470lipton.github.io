import AppIntents
import WidgetKit

/// Press and hold › Edit Widget: which nogs a Nogitivity widget offers to start.
struct NogitivityConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Nogitivity"
    static var description = IntentDescription("Start a nog right from your Home Screen, then watch its timer.")

    @Parameter(title: "Lists", default: [.nogging, .loose])
    var lists: [NogWidgetList]

    @Parameter(title: "Only #tag", description: "Show only nogs with this tag, like kitchen or calls.")
    var tag: String?

    @Parameter(title: "Pick nogs", description: "Choose nogs one by one instead of using the lists.")
    var nogs: [NogWidgetEntity]?

    @Parameter(title: "Show the timer while I'm doing something", default: true)
    var showTimer: Bool

    init() {}

    init(lists: [NogWidgetList], tag: String? = nil, nogs: [NogWidgetEntity]? = nil, showTimer: Bool = true) {
        self.lists = lists
        self.tag = tag
        self.nogs = nogs
        self.showTimer = showTimer
    }

    /// "Nogging now + Loose nogs", "#kitchen" or "Your picks".
    var label: String {
        if let nogs, !nogs.isEmpty { return "Your picks" }
        if let tag = tag.map(WidgetPicker.cleanTag), !tag.isEmpty { return "#\(tag)" }
        return lists.isEmpty ? "Nogging now" : lists.map(\.kind.title).joined(separator: " + ")
    }

    var listKinds: [WidgetListKind] {
        lists.isEmpty ? [.nogging, .loose] : lists.map(\.kind)
    }
}

enum NogWidgetList: String, AppEnum {
    case nogging, today, agenda, loose, dream

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Nog List"
    static var caseDisplayRepresentations: [NogWidgetList: DisplayRepresentation] = [
        .nogging: "Nogging now",
        .today: "Today",
        .agenda: "Agenda",
        .loose: "Loose nogs",
        .dream: "Dream nogs",
    ]

    var kind: WidgetListKind { WidgetListKind(rawValue: rawValue) ?? .nogging }
}

/// An outstanding nog, as the widget's Edit sheet lists it.
struct NogWidgetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Nog"
    static var defaultQuery = NogWidgetQuery()

    var id: UUID
    var title: String
    var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    init(id: UUID, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }

    init(_ entry: WidgetSnapshot.Entry, now: Date = .now) {
        var detail: String
        if entry.isDoing {
            detail = "Doing"
        } else if entry.isDream {
            detail = "Dream nog"
        } else if entry.isNogging(at: now) {
            detail = "Nogging now"
        } else if let when = entry.when(at: now) {
            detail = when.formatted(.relative(presentation: .named))
        } else {
            detail = "Loose nog"
        }
        if let parent = entry.parentTitle { detail += " · \(parent)" }
        self.init(id: entry.id, title: entry.title, detail: detail)
    }
}

/// Reads the app's widget snapshot; offers open nogs, nogging ones first.
struct NogWidgetQuery: EntityStringQuery {
    private var outstanding: [WidgetSnapshot.Entry] {
        let now = Date.now
        let snapshot = WidgetStore.load() ?? .empty
        return (snapshot.outstanding + snapshot.entries.filter(\.isDream)).sorted { a, b in
            let an = a.isNogging(at: now) || a.isDoing, bn = b.isNogging(at: now) || b.isDoing
            if an != bn { return an }
            let aw = a.when(at: now) ?? .distantFuture, bw = b.when(at: now) ?? .distantFuture
            return aw != bw ? aw < bw : a.updated > b.updated
        }
    }

    func entities(for identifiers: [UUID]) async throws -> [NogWidgetEntity] {
        let byID = Dictionary((WidgetStore.load() ?? .empty).entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return identifiers.compactMap { byID[$0].map { NogWidgetEntity($0) } }
    }

    func entities(matching string: String) async throws -> [NogWidgetEntity] {
        outstanding.filter { $0.title.localizedStandardContains(string) }.map { NogWidgetEntity($0) }
    }

    func suggestedEntities() async throws -> [NogWidgetEntity] {
        outstanding.prefix(50).map { NogWidgetEntity($0) }
    }
}
