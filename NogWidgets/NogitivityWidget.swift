import AppIntents
import SwiftUI
import WidgetKit

// Nogitivity: what's on now, at a glance. Read-only: tap a nog to open it, + to take one.
// While you're doing something it shows the timer. Two styles, picked in Edit Widget:
// a time list, or the one nog that matters most.

struct NogitivityWidget: Widget {
    static let kind = "Nogitivity"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: NogitivityConfiguration.self, provider: NogitivityProvider()) { entry in
            NogitivityView(entry: entry)
        }
        .configurationDisplayName("Nog")
        .description("What's on now, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Timeline

struct NogitivityEntry: TimelineEntry {
    let date: Date
    /// nil until the app has written its first snapshot.
    let snapshot: WidgetSnapshot?
    let configuration: NogitivityConfiguration

    /// The nog whose timer to show, if any.
    var doing: WidgetSnapshot.Entry? {
        guard configuration.showTimer, let snapshot else { return nil }
        // A picked nog you're doing wins over anything else you're doing.
        let picked = Set((configuration.nogs ?? []).map(\.id))
        return snapshot.entries.filter { $0.isDoing && picked.contains($0.id) }.first ?? snapshot.doing
    }

    var sections: [WidgetPicker.Section] {
        guard let snapshot else { return [] }
        return WidgetPicker.sections(snapshot, lists: configuration.listKinds, tag: configuration.tag,
                                     pinned: (configuration.nogs ?? []).map(\.id),
                                     excluding: doing?.id, at: date)
    }

    var picks: [WidgetSnapshot.Entry] { sections.flatMap(\.entries) }

    /// Nogging right now, from everything (the Lock Screen's count).
    var nogging: [WidgetSnapshot.Entry] {
        (snapshot?.entries ?? []).filter { $0.isNogging(at: date) }
            .sorted { ($0.start ?? date) < ($1.start ?? date) }
    }

    /// The next nog still to come today or later.
    var nextNog: WidgetSnapshot.Entry? {
        (snapshot?.entries ?? []).filter { $0.isOpen && !$0.isNogging(at: date) && $0.when(at: date) != nil }
            .min { ($0.when(at: date) ?? .distantFuture) < ($1.when(at: date) ?? .distantFuture) }
    }

    /// Nogs on today: doing, nogging, or due later today (the Lock Screen's count).
    var todayCount: Int {
        (snapshot?.entries ?? []).filter { item in
            item.isDoing || (item.isOpen && (item.isNogging(at: date)
                || item.when(at: date).map { Calendar.current.isDate($0, inSameDayAs: date) } == true))
        }.count
    }

    var showsTitlesOnLockScreen: Bool { snapshot?.showTitlesOnLockScreen ?? true }
}

struct NogitivityProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NogitivityEntry {
        NogitivityEntry(date: .now, snapshot: .sample(), configuration: NogitivityConfiguration())
    }

    func snapshot(for configuration: NogitivityConfiguration, in context: Context) async -> NogitivityEntry {
        let snapshot = context.isPreview ? WidgetSnapshot.sample() : (WidgetStore.load() ?? .sample())
        return NogitivityEntry(date: .now, snapshot: snapshot, configuration: configuration)
    }

    func timeline(for configuration: NogitivityConfiguration, in context: Context) async -> Timeline<NogitivityEntry> {
        let now = Date.now
        let snapshot = WidgetStore.load()
        // Redraw when a nog starts nogging or a timebox runs out; timers tick by themselves.
        // The app reloads the widgets whenever anything else changes.
        // Ask again at midnight (for Today) or in 6 hours at the latest.
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        let reloadAt = min(midnight, now.addingTimeInterval(6 * 3600))
        let changes = snapshot.map { WidgetPicker.changeDates($0, after: now) } ?? []
        let dates = [now] + changes.filter { $0 < reloadAt }
        let entries = dates.map { NogitivityEntry(date: $0, snapshot: snapshot, configuration: configuration) }
        return Timeline(entries: entries, policy: .after(reloadAt))
    }
}

// MARK: - Colors

private enum W {
    /// The glowing readout blue of the timers.
    static let readout = Color(light: 0x1D5CA3, dark: 0xCFE9FF)
    static let amber = Color(light: 0xB86E00, dark: 0xFFB65C)
    static let listBackground = Color(light: 0xF6EEDF, dark: 0x140E26)
    static let timerBackground = Color(light: 0xFBF5EA, dark: 0x0C0818)
    /// The + on the pink circle.
    static let onPink = Color(light: 0xFFFFFF, dark: 0x140E26)
    static let rule = Theme.muted.opacity(0.25)

    static func label(_ size: CGFloat = 11) -> Font { .custom("Futura-Medium", size: size) }
}

// MARK: - Views

struct NogitivityView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NogitivityEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            LockCircular(entry: entry).containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular:
            LockRectangular(entry: entry).containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryInline:
            LockInline(entry: entry).containerBackground(for: .widget) { Color.clear }
        default:
            if entry.snapshot == nil {
                NotSetUp().containerBackground(W.listBackground, for: .widget)
            } else if let doing = entry.doing {
                TimerWidget(entry: entry, item: doing)
                    .containerBackground(W.timerBackground, for: .widget)
                    .widgetURL(itemURL(doing.id))
            } else {
                NowWidget(entry: entry)
                    .containerBackground(W.listBackground, for: .widget)
            }
        }
    }
}

private func itemURL(_ id: UUID) -> URL? { URL(string: "nog://item/\(id.uuidString)") }
private let captureURL = URL(string: "nog://capture")!

private struct NotSetUp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOW").font(W.label()).tracking(1.8).foregroundStyle(Theme.muted)
            Text("Open Nog once to see your nogs here.")
                .font(.system(size: 13.5, weight: .medium))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Timer (while doing)

/// Counts down a timebox, or up when open-ended. "TIME'S UP" once past the end.
private struct DoingTimer: View {
    let item: WidgetSnapshot.Entry
    let date: Date

    var body: some View {
        if let end = item.timeboxEnd {
            if end <= date {
                Text("TIME'S UP").foregroundStyle(Theme.pink)
            } else {
                Text(timerInterval: min(item.doingSince ?? date, end)...end, countsDown: true)
            }
        } else {
            Text(item.doingSince ?? date, style: .timer)
        }
    }
}

private struct GlowingTimer: View {
    let item: WidgetSnapshot.Entry
    let date: Date
    let size: CGFloat
    var alignment: TextAlignment = .leading

    var body: some View {
        DoingTimer(item: item, date: date)
            .font(.nogReadout(size))
            .foregroundStyle(W.readout)
            .nogGlow(color: Theme.blue.opacity(0.6), radius: 6)
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

private struct TimeboxBar: View {
    let item: WidgetSnapshot.Entry
    let date: Date

    var body: some View {
        if let since = item.doingSince, let end = item.timeboxEnd, end > date {
            ProgressView(timerInterval: min(since, end)...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(Theme.violet)
            .accessibilityHidden(true) // the timer already says how long is left
        }
    }
}

/// Read-only, like the rest of the widget: the timer to glance at. Done, +10 and Stop
/// live in the Live Activity and the app.
private struct TimerWidget: View {
    @Environment(\.widgetFamily) private var family
    let entry: NogitivityEntry
    let item: WidgetSnapshot.Entry

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemLarge: large
        default: medium
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("▶ DOING").font(W.label()).tracking(1.8).foregroundStyle(Theme.blue)
            Spacer(minLength: 4)
            if family != .systemSmall, let box = item.timeboxMinutes {
                Text("\(box) MIN BOX").font(.nogMeta).foregroundStyle(Theme.muted)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(3)
            Spacer(minLength: 0)
            GlowingTimer(item: item, date: entry.date, size: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .center, spacing: 12) {
                Text(item.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlowingTimer(item: item, date: entry.date, size: 38, alignment: .trailing)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
            TimeboxBar(item: item, date: entry.date)
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .center, spacing: 12) {
                Text(item.title).font(.system(size: 19, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlowingTimer(item: item, date: entry.date, size: 40, alignment: .trailing)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            TimeboxBar(item: item, date: entry.date)

            if item.subTotal > 0 {
                Text("SUB-NOGS · \(item.subDone) OF \(item.subTotal)")
                    .font(W.label()).tracking(1.8).foregroundStyle(Theme.muted)
                    .padding(.top, 4)
                ForEach(Array(item.subItems.prefix(3).enumerated()), id: \.offset) { _, sub in
                    SubItemRow(sub: sub)
                }
            }

            let upNext = Array(entry.picks.prefix(item.subTotal > 0 ? 2 : 4))
            if !upNext.isEmpty {
                Text("NEXT").font(W.label()).tracking(1.8).foregroundStyle(Theme.muted).padding(.top, 4)
                ForEach(upNext) { next in
                    TimeRow(item: next, date: entry.date, size: .large, titleSize: 15)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SubItemRow: View {
    let sub: WidgetSnapshot.SubItem

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if sub.done {
                    Circle().fill(Theme.blue)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(W.timerBackground)
                } else {
                    Circle().strokeBorder(Theme.muted, lineWidth: 1.5)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(sub.title)
                .font(.system(size: 13.5))
                .strikethrough(sub.done)
                .foregroundStyle(sub.done ? Theme.muted : .primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(sub.done ? "Done" : "")
    }
}

// MARK: What's on now (nothing being timed)

// A dashboard to glance at, not a place to act: no Start, no Done. Tap a nog to open
// it, or the + to take a new one. Two styles, picked in Edit Widget:
// Time list: "NOW · 3" with times, then "LATER". One thing: the nog that matters most, big, then "NEXT".

private enum RowSize {
    case small, medium, large

    private func pick(_ small: CGFloat, _ medium: CGFloat, _ large: CGFloat) -> CGFloat {
        switch self {
        case .small: small
        case .medium: medium
        case .large: large
        }
    }

    var time: CGFloat { pick(11, 12, 13) }
    var timeWidth: CGFloat { pick(32, 40, 46) }
    var gap: CGFloat { pick(6, 10, 10) }
    var title: CGFloat { pick(13.5, 15, 17) }
    /// The first nog in the list, a size up and semibold.
    var lead: CGFloat { pick(15, 17, 19) }
    var minHeight: CGFloat? { self == .large ? 44 : nil }
}

/// "9:10", "Thu" or "Nov 14": when it started nogging, or when it will.
private func moment(of item: WidgetSnapshot.Entry, at date: Date) -> String? {
    let onNow = item.isDoing || item.isNogging(at: date)
    guard let when = onNow ? (item.doingSince ?? item.start) : item.when(at: date) else { return nil }
    let calendar = Calendar.current
    if calendar.isDate(when, inSameDayAs: date) {
        return when.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }
    if when > date, when < date.addingTimeInterval(6 * 86_400) {
        return when.formatted(.dateTime.weekday(.abbreviated))
    }
    return when.formatted(.dateTime.month(.abbreviated).day())
}

/// One nog: its time, its title (and a bell for alarms). Opens the nog.
private struct TimeRow: View {
    let item: WidgetSnapshot.Entry
    let date: Date
    let size: RowSize
    var titleSize: CGFloat? = nil
    var bold = false
    var detail: String? = nil
    var label: String? = nil

    var body: some View {
        Link(destination: itemURL(item.id)!) {
            HStack(alignment: .firstTextBaseline, spacing: size.gap) {
                if let label {
                    Text(label).font(W.label(size == .large ? 12 : 11)).tracking(1.8).foregroundStyle(Theme.muted)
                        .frame(width: size.timeWidth, alignment: .leading)
                }
                Text(moment(of: item, at: date) ?? "")
                    .font(.system(size: size.time, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .frame(width: label == nil ? size.timeWidth : nil, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: titleSize ?? (bold ? size.lead : size.title), weight: bold ? .semibold : .regular))
                        .lineLimit(1)
                    if let detail {
                        Text(detail).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                if item.alarm {
                    Image(systemName: "bell.fill").font(.system(size: size.time)).foregroundStyle(W.amber)
                        .accessibilityLabel("Alarm")
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: size.minHeight)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Rule: View {
    var body: some View { Rectangle().fill(W.rule).frame(height: 1).accessibilityHidden(true) }
}

/// The + to take a new nog: a plain 44 pt circle. The small widget is one tap target,
/// so there the + is a button that opens capture and the rest of the widget opens the nog.
private struct AddButton: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemSmall {
            Button(intent: OpenURLIntent(captureURL)) { circle }.buttonStyle(.plain)
                .accessibilityLabel("Take a Nog")
                .accessibilityHint("Opens Nog to add something new")
        } else {
            Link(destination: captureURL) { circle }
                .accessibilityLabel("Take a Nog")
                .accessibilityHint("Opens Nog to add something new")
        }
    }

    private var circle: some View {
        Image(systemName: "plus")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(W.onPink)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Theme.pink))
            .contentShape(Circle())
    }
}

private struct NowWidget: View {
    @Environment(\.widgetFamily) private var family
    let entry: NogitivityEntry

    private var size: RowSize {
        switch family {
        case .systemSmall: .small
        case .systemLarge: .large
        default: .medium
        }
    }

    private var picks: [WidgetSnapshot.Entry] { entry.picks }
    private func isOnNow(_ item: WidgetSnapshot.Entry) -> Bool { item.isDoing || item.isNogging(at: entry.date) }
    private var now: [WidgetSnapshot.Entry] { picks.filter(isOnNow) }
    private var later: [WidgetSnapshot.Entry] { picks.filter { !isOnNow($0) } }

    /// The default widget (Now, no tag, no picks): the later part is the rest of today.
    private var isNowList: Bool {
        let config = entry.configuration
        return config.listKinds == [.now] && (config.nogs ?? []).isEmpty
            && (config.tag.map { WidgetPicker.cleanTag($0).isEmpty } ?? true)
    }

    private var laterTitle: String {
        if isNowList { return size == .large ? "LATER TODAY" : "LATER" }
        return entry.configuration.label.uppercased()
    }

    private var labelSize: CGFloat { size == .large ? 13 : 11 }
    /// Room kept clear for the + (top right on medium and large, bottom right on small).
    private let buttonRoom: CGFloat = 52

    var body: some View {
        Group {
            switch entry.configuration.style {
            case .timeList: timeList
            case .oneThing: oneThing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: family == .systemSmall ? .bottomTrailing : .topTrailing) {
            AddButton().offset(x: 2, y: family == .systemSmall ? 2 : -2)
        }
        .widgetURL(family == .systemSmall ? smallURL : nil)
    }

    /// The small widget is one tap: the nog at the top, or capture when there's nothing on.
    private var smallURL: URL? {
        (now.first ?? later.first).flatMap { itemURL($0.id) } ?? captureURL
    }

    private func sectionLabel(_ text: String, color: Color, tall: Bool = false) -> some View {
        Text(text).font(W.label(labelSize)).tracking(1.8).foregroundStyle(color).lineLimit(1)
            .frame(minHeight: tall ? 44 : nil, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var nothingOn: some View {
        Text("Nothing on now.").font(.system(size: size.title)).foregroundStyle(Theme.muted)
    }

    // MARK: Time list

    @ViewBuilder
    private var timeList: some View {
        let rows = size == .large ? 5 : 4
        let nowShown = Array(now.prefix(later.isEmpty ? rows : rows - 1))
        let laterShown = Array(later.prefix(rows - nowShown.count))
        VStack(alignment: .leading, spacing: size == .large ? 0 : 5) {
            sectionLabel(now.isEmpty ? "NOW" : "NOW · \(now.count)", color: now.isEmpty ? Theme.muted : Theme.pink,
                         tall: size == .large)
                .padding(.trailing, size == .small ? 0 : buttonRoom)
            if now.isEmpty { nothingOn }
            ForEach(Array(nowShown.enumerated()), id: \.element.id) { index, item in
                TimeRow(item: item, date: entry.date, size: size, bold: index == 0,
                        detail: size == .large && index == 0 ? item.suggestedMinutes.map { "~\(IntervalLabel.amount($0))" } : nil)
                    .padding(.trailing, size == .medium && index < 2 ? buttonRoom : 0)
                if size == .large && index < nowShown.count - 1 { Rule() }
            }
            if !laterShown.isEmpty {
                sectionLabel(laterTitle, color: Theme.muted)
                    .padding(.top, size == .large ? 6 : 3)
                ForEach(Array(laterShown.enumerated()), id: \.element.id) { index, item in
                    TimeRow(item: item, date: entry.date, size: size)
                        .padding(.trailing, size == .small && index == laterShown.count - 1 ? buttonRoom - 2 : 0)
                }
            }
            if size == .large {
                Spacer(minLength: 0)
                if isNowList && laterShown.count == later.count && nowShown.count == now.count {
                    Text(picks.isEmpty ? "Nothing on today." : "Nothing else today.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: One thing

    @ViewBuilder
    private var oneThing: some View {
        if let hero = now.first ?? later.first {
            let heroIsNow = !now.isEmpty
            let more = heroIsNow ? Array(now.dropFirst()) : []
            let next = heroIsNow ? later.first : later.dropFirst().first
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel(heroIsNow ? "NOW" : (isNowList ? "NEXT" : laterTitle),
                             color: heroIsNow ? Theme.pink : Theme.muted)
                Link(destination: itemURL(hero.id)!) {
                    VStack(alignment: .leading, spacing: size == .large ? 4 : 2) {
                        Text(hero.title)
                            .font(.system(size: heroSize, weight: .semibold))
                            .lineLimit(size == .medium ? 2 : 3)
                            .minimumScaleFactor(0.85)
                        if let detail = heroDetail(hero, isNow: heroIsNow, more: more.count) {
                            Text(detail).font(.system(size: size == .large ? 15 : (size == .small ? 12 : 13)))
                                .foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, size == .small ? 0 : buttonRoom)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)

                switch size {
                case .small:
                    if let next, let when = moment(of: next, at: entry.date) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("NEXT").font(W.label()).tracking(1.8)
                            Text(when).font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(Theme.muted)
                        .padding(.trailing, buttonRoom)
                        .padding(.bottom, 4)
                        .accessibilityElement(children: .combine)
                    }
                case .medium:
                    if let next {
                        Rule()
                        TimeRow(item: next, date: entry.date, size: .medium, label: "NEXT").padding(.top, 4)
                    }
                case .large:
                    if !more.isEmpty {
                        Rule()
                        sectionLabel("MORE NOW · \(more.count)", color: Theme.pink).padding(.top, 8)
                        ForEach(more.prefix(next == nil ? 3 : 2)) { item in
                            TimeRow(item: item, date: entry.date, size: .large)
                        }
                    }
                    if let next {
                        Rule().padding(.top, more.isEmpty ? 0 : 4)
                        TimeRow(item: next, date: entry.date, size: .large, label: "NEXT")
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("NOW", color: Theme.muted)
                Text("Nothing on now.")
                    .font(.system(size: heroSize, weight: .semibold))
                    .padding(.trailing, size == .small ? 0 : buttonRoom)
            }
        }
    }

    private var heroSize: CGFloat {
        switch size {
        case .small: 20
        case .medium: 22
        case .large: 28
        }
    }

    /// "Since 9:10 · 2 more", "Since 9:10 · ~15 min", "12:40", "No time".
    private func heroDetail(_ hero: WidgetSnapshot.Entry, isNow: Bool, more: Int) -> String? {
        var parts: [String] = []
        if let when = moment(of: hero, at: entry.date) {
            parts.append(isNow ? "Since \(when)" : when)
        } else if !isNow {
            parts.append(hero.isDream ? "Someday" : "No time")
        }
        if size == .large {
            if let box = hero.suggestedMinutes { parts.append("~\(IntervalLabel.amount(box))") }
        } else if more > 0 {
            parts.append(size == .small ? "\(more) more" : "\(more) more on now")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Lock Screen

private extension NogitivityEntry {
    /// Respects Settings › "Show titles on Lock Screen".
    func lockTitle(_ item: WidgetSnapshot.Entry) -> String {
        showsTitlesOnLockScreen ? item.title : "A nog"
    }
}

/// Doing: a ring filling as the timebox runs. Otherwise: how many are nogging.
private struct LockCircular: View {
    let entry: NogitivityEntry

    var body: some View {
        if let item = entry.doing {
            ZStack {
                if let since = item.doingSince, let end = item.timeboxEnd, end > entry.date {
                    ProgressView(timerInterval: min(since, end)...end, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.circular)
                }
                VStack(spacing: 0) {
                    Image(systemName: "play.fill").font(.system(size: 8, weight: .semibold))
                    DoingTimer(item: item, date: entry.date)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 44)
                }
            }
            .widgetAccentable()
            .widgetURL(itemURL(item.id))
        } else {
            VStack(spacing: 0) {
                Image(systemName: entry.nogging.isEmpty ? "bell" : "bell.badge").font(.system(size: 15))
                Text("\(entry.nogging.count)").font(.system(size: 22, weight: .bold)).lineLimit(1)
            }
            .widgetAccentable()
            .accessibilityLabel("\(entry.nogging.count) nogging")
        }
    }
}

private struct LockRectangular: View {
    let entry: NogitivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let item = entry.doing {
                header("▶ \(entry.lockTitle(item).uppercased())")
                timerLine(item)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if !entry.nogging.isEmpty {
                header("NOW")
                ForEach(entry.nogging.prefix(2)) { item in
                    Text("· \(entry.lockTitle(item))").font(.system(size: 13)).lineLimit(1)
                }
            } else if let next = entry.nextNog, let when = next.when(at: entry.date) {
                header("NEXT · \(when.formatted(date: .omitted, time: .shortened))")
                Text(entry.lockTitle(next)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let detail = detail(next) {
                    Text(detail).font(.system(size: 11)).lineLimit(1)
                }
            } else {
                header("NOG")
                Text("Nothing nogging").font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(entry.doing.flatMap { itemURL($0.id) })
    }

    /// The carton, the state ("NOW", "NEXT · 12:40 PM") and how many nogs are on today.
    private func header(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image("Carton").resizable().scaledToFit()
                .frame(width: 12, height: 12)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                .accessibilityHidden(true)
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(entry.todayCount) today")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .lineLimit(1).layoutPriority(1)
                .accessibilityLabel(entry.todayCount == 1 ? "1 nog today" : "\(entry.todayCount) nogs today")
        }
        .widgetAccentable()
    }

    /// "12:04 of 25".
    private func timerLine(_ item: WidgetSnapshot.Entry) -> Text {
        if let end = item.timeboxEnd {
            if end <= entry.date { return Text("TIME'S UP") }
            let timer = Text(timerInterval: min(item.doingSince ?? entry.date, end)...end, countsDown: true)
            guard let minutes = item.timeboxMinutes else { return timer }
            let total = Text(" of \(minutes)").font(.system(size: 11))
            return Text("\(timer)\(total)")
        }
        return Text(item.doingSince ?? entry.date, style: .timer)
    }

    /// "Alarm · 1/3 sub-items".
    private func detail(_ item: WidgetSnapshot.Entry) -> String? {
        var parts: [String] = []
        if item.alarm { parts.append("Alarm") }
        if item.subTotal > 0 { parts.append("\(item.subDone)/\(item.subTotal) sub-nogs") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct LockInline: View {
    let entry: NogitivityEntry

    var body: some View {
        if let item = entry.doing {
            if let end = item.timeboxEnd, end > entry.date {
                Label {
                    Text("\(entry.lockTitle(item)) · \(Text(timerInterval: min(item.doingSince ?? entry.date, end)...end, countsDown: true))")
                } icon: {
                    Image(systemName: "play.fill")
                }
            } else {
                Label("\(entry.lockTitle(item)) · time's up", systemImage: "play.fill")
            }
        } else {
            let nogging = entry.nogging.count
            let next = entry.nextNog?.when(at: entry.date).map { " · next \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            Label(nogging > 0 ? "\(nogging) nogging\(next)" : "Nothing nogging\(next)", systemImage: "bell")
        }
    }
}

// MARK: - Sample data (widget gallery and placeholders)

enum IntervalLabel {
    /// 15 → "15 min", 60 → "1 hour", 90 → "1h 30m".
    static func amount(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

extension WidgetSnapshot {
    /// The mockups' nogs, so the widget gallery shows something real-looking.
    static func sample(now: Date = .now) -> WidgetSnapshot {
        func entry(_ title: String, status: String = "open", start: TimeInterval? = nil, alarm: Bool = false,
                   minutes: Int?, tags: [String] = []) -> Entry {
            Entry(id: UUID(), title: title, status: status, tags: tags, parentTitle: nil,
                  start: start.map { now.addingTimeInterval($0) }, nextNog: nil, alarm: alarm,
                  suggestedMinutes: minutes, doingSince: nil, timeboxMinutes: nil,
                  subItems: [], subDone: 0, subTotal: 0, updated: now)
        }
        return WidgetSnapshot(generated: now, entries: [
            entry("Call the plumber", start: -1800, minutes: 15, tags: ["calls"]),
            entry("Reply to Ana about Friday", start: -600, minutes: 5),
            entry("Pay the electric bill", start: -60, minutes: 10),
            entry("Pick up paint samples", start: 3 * 3600, alarm: true, minutes: 25, tags: ["kitchen"]),
            entry("Sort the garage shelves", minutes: 45),
            entry("Back up the laptop", minutes: 25),
            entry("Read the lease renewal", minutes: 15),
        ], showTitlesOnLockScreen: true)
    }
}

// MARK: - Previews

#Preview("Time list", as: .systemMedium) {
    NogitivityWidget()
} timeline: {
    NogitivityEntry(date: .now, snapshot: .sample(), configuration: NogitivityConfiguration())
}

#Preview("One thing", as: .systemMedium) {
    NogitivityWidget()
} timeline: {
    NogitivityEntry(date: .now, snapshot: .sample(), configuration: NogitivityConfiguration(style: .oneThing))
}

#Preview("Time list, large", as: .systemLarge) {
    NogitivityWidget()
} timeline: {
    NogitivityEntry(date: .now, snapshot: .sample(), configuration: NogitivityConfiguration())
}

#Preview("Timer", as: .systemMedium) {
    NogitivityWidget()
} timeline: {
    NogitivityEntry(date: .now, snapshot: .sampleDoing(), configuration: NogitivityConfiguration(lists: [.nogging]))
}

#Preview("Timer, Lock Screen", as: .accessoryRectangular) {
    NogitivityWidget()
} timeline: {
    NogitivityEntry(date: .now, snapshot: .sampleDoing(), configuration: NogitivityConfiguration(lists: [.nogging]))
}

extension WidgetSnapshot {
    static func sampleDoing(now: Date = .now) -> WidgetSnapshot {
        var snapshot = sample(now: now)
        snapshot.entries.insert(Entry(
            id: UUID(), title: "Write the reno budget", status: "doing", tags: [], parentTitle: "Kitchen reno",
            start: nil, nextNog: nil, alarm: false, suggestedMinutes: 25,
            doingSince: now.addingTimeInterval(-12 * 60), timeboxMinutes: 25,
            subItems: [SubItem(title: "Tile and fixtures", done: false), SubItem(title: "Contingency (10%)", done: false),
                       SubItem(title: "Quotes from two plumbers", done: true)],
            subDone: 1, subTotal: 3, updated: now), at: 0)
        return snapshot
    }
}
