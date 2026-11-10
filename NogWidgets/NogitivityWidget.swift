import AppIntents
import SwiftUI
import WidgetKit

// Nogitivity: start a nog from the Home Screen, then watch its timer.
// While you're doing something it's the timer (with Done / +10 / Stop); otherwise
// it puts the nog that matters most right now up front with Start / Done, a
// "Take a Nog" button, and a short list of what else is about now.

struct NogitivityWidget: Widget {
    static let kind = "Nogitivity"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: NogitivityConfiguration.self, provider: NogitivityProvider()) { entry in
            NogitivityView(entry: entry)
        }
        .configurationDisplayName("Nogitivity")
        .description("Pick a nog and start it. While you're on it, see the timer.")
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
    static let mint = ProgressRing.complete
    static let amber = Color(light: 0xB86E00, dark: 0xFFB65C)
    /// The glowing readout blue of the timers.
    static let readout = Color(light: 0x1C7ED6, dark: 0xBFE3FF)
    static let listBackground = Color(light: 0xF6F7FA, dark: 0x16171E)
    static let timerBackground = Color(light: 0xEEF4FB, dark: 0x08090C)
    /// The card behind the nog that matters most right now.
    static let heroFill = Color(light: 0xFFFFFF, dark: 0x1F2029)

    static func label(_ size: CGFloat = 9.5) -> Font { .custom("Futura-Medium", size: size) }

    /// Pink while nogging, amber for alarms, blue for later, gray for loose, violet for dreams.
    static func dot(for entry: WidgetSnapshot.Entry, at date: Date) -> Color {
        if entry.isDream { return Theme.violet }
        if entry.isNogging(at: date) { return entry.alarm ? amber : Theme.pink }
        if entry.start != nil { return entry.alarm ? amber : Theme.blue }
        return Theme.muted
    }
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
                PickWidget(entry: entry)
                    .containerBackground(W.listBackground, for: .widget)
            }
        }
    }
}

private func itemURL(_ id: UUID) -> URL? { URL(string: "nog://item/\(id.uuidString)") }
private let captureURL = URL(string: "nog://capture")

private struct NotSetUp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("▶ NOGITIVITY").font(W.label()).tracking(1.8).foregroundStyle(Theme.blue)
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
        }
    }
}

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
            Text("▶ NOGITIVITY").font(W.label(family == .systemSmall ? 9.5 : 11)).tracking(1.8).foregroundStyle(Theme.blue)
            Spacer(minLength: 4)
            if family != .systemSmall, let box = item.timeboxMinutes {
                Text("\(box) MIN BOX").font(.nogMeta).foregroundStyle(Theme.muted)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Text(item.title).font(.system(size: 13.5, weight: .medium)).lineLimit(2)
            GlowingTimer(item: item, date: entry.date, size: 32)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button(intent: CompleteItemIntent(itemID: item.id.uuidString)) {
                    PillLabel(text: "✓ Done", tint: W.mint, height: 32, bold: true)
                }
                Button(intent: ExtendTimeboxIntent(itemID: item.id.uuidString, minutes: 10)) {
                    PillLabel(text: "+10", tint: Theme.pink, height: 32).frame(width: 48)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(alignment: .center, spacing: 12) {
                Text(item.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlowingTimer(item: item, date: entry.date, size: 34, alignment: .trailing)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
            TimeboxBar(item: item, date: entry.date)
            Spacer(minLength: 0)
            buttons(withStop: true)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .center, spacing: 12) {
                Text(item.title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlowingTimer(item: item, date: entry.date, size: 40, alignment: .trailing)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            TimeboxBar(item: item, date: entry.date)

            if item.subTotal > 0 {
                Text("ITS SUB-NOGS · \(item.subDone) OF \(item.subTotal)")
                    .font(W.label()).tracking(1.8).foregroundStyle(Theme.muted)
                    .padding(.top, 4)
                ForEach(Array(item.subItems.prefix(3).enumerated()), id: \.offset) { _, sub in
                    SubItemRow(sub: sub)
                }
            }

            let upNext = Array(entry.picks.prefix(item.subTotal > 0 ? 2 : 4))
            if !upNext.isEmpty {
                Text("UP NEXT").font(W.label()).tracking(1.8).foregroundStyle(Theme.muted).padding(.top, 4)
                ForEach(upNext) { next in
                    HStack(spacing: 8) {
                        Text(next.title).font(.system(size: 13.5)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        StartButton(entry: next, height: 28)
                    }
                }
            }
            Spacer(minLength: 0)
            buttons(withStop: false)
        }
    }

    private func buttons(withStop: Bool) -> some View {
        HStack(spacing: 6) {
            Button(intent: CompleteItemIntent(itemID: item.id.uuidString)) {
                PillLabel(text: "✓ Done", tint: W.mint, height: 34, bold: true)
            }
            Button(intent: ExtendTimeboxIntent(itemID: item.id.uuidString, minutes: 10)) {
                PillLabel(text: "+10 min", tint: Theme.pink, height: 34).frame(width: 92)
            }
            if withStop {
                Button(intent: StopDoingIntent(itemID: item.id.uuidString)) {
                    PillLabel(systemImage: "stop.fill", tint: Theme.muted, height: 34).frame(width: 40)
                }
                .accessibilityLabel("Stop")
            }
        }
        .buttonStyle(.plain)
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
            Text(sub.title)
                .font(.system(size: 13.5))
                .strikethrough(sub.done)
                .foregroundStyle(sub.done ? Theme.muted : .primary)
                .lineLimit(1)
        }
    }
}

// MARK: Start, finish or add a nog (nothing on)

// About 60% of the widget is for acting: the nog that matters most right now, big, with
// Start / Done (and Later on the large size), plus "Take a Nog" to add a new one.
// The other 40% lists what else is about now, each with its own ▶︎.

private struct PickWidget: View {
    @Environment(\.widgetFamily) private var family
    let entry: NogitivityEntry

    var body: some View {
        let picks = entry.picks
        if picks.isEmpty {
            empty
        } else {
            switch family {
            case .systemSmall: smallBody(picks)
            case .systemLarge: large(hero: picks[0], rest: Array(picks.dropFirst()))
            default: medium(hero: picks[0], rest: Array(picks.dropFirst()))
            }
        }
    }

    // MARK: Nothing about now

    private var empty: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            Text("NOTHING NOGGING").font(W.label(family == .systemSmall ? 9.5 : 11)).tracking(1.8).foregroundStyle(W.mint)
            Text("You're clear for now.")
                .font(.system(size: family == .systemSmall ? 15 : 17, weight: .semibold))
                .lineLimit(2)
            if family != .systemSmall {
                Text(entry.configuration.label).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            // The whole small widget opens capture; bigger ones get a real button.
            if family == .systemSmall {
                TakeANogLabel(height: 38)
            } else {
                Link(destination: captureURL!) { TakeANogLabel(height: 44) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(captureURL)
    }

    // MARK: Small

    /// A tag or a hand-picked set reads best as a short list; otherwise the top nog, big.
    @ViewBuilder
    private func smallBody(_ picks: [WidgetSnapshot.Entry]) -> some View {
        let config = entry.configuration
        let isList = (config.tag.map { !WidgetPicker.cleanTag($0).isEmpty } ?? false) || (config.nogs?.count ?? 0) > 1
        if isList { smallList(picks) } else { smallTop(picks[0]) }
    }

    private func smallTop(_ top: WidgetSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HeroDetail(item: top, date: entry.date, size: 9.5)
            Text(top.title).font(.system(size: 15, weight: .semibold)).lineLimit(3)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button(intent: StartDoingIntent(itemID: top.id.uuidString)) {
                    PillLabel(text: BoxFormat.short(top.suggestedMinutes).map { "▶ \($0)" } ?? "▶ Start",
                              tint: Theme.blue, height: 38, bold: true)
                }
                .accessibilityLabel(startLabel(top))
                Button(intent: CompleteItemIntent(itemID: top.id.uuidString)) {
                    PillLabel(systemImage: "checkmark", tint: W.mint, height: 38).frame(width: 44)
                }
                .accessibilityLabel("Mark \(top.title) done")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(itemURL(top.id))
    }

    private func smallList(_ picks: [WidgetSnapshot.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entry.configuration.label.uppercased()) · \(picks.count)")
                .font(W.label()).tracking(1.8).foregroundStyle(W.amber).lineLimit(1)
            ForEach(picks.prefix(3)) { item in
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 12.5)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StartButton(entry: item, height: 26, compact: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Medium: act on the left (60%), the rest of now on the right (40%)

    private func medium(hero: WidgetSnapshot.Entry, rest: [WidgetSnapshot.Entry]) -> some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Link(destination: captureURL!) { TakeANogLabel(height: 28) }
                    Link(destination: itemURL(hero.id)!) {
                        VStack(alignment: .leading, spacing: 2) {
                            HeroDetail(item: hero, date: entry.date, size: 9.5)
                            Text(hero.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Button(intent: StartDoingIntent(itemID: hero.id.uuidString)) {
                            PillLabel(text: BoxFormat.short(hero.suggestedMinutes).map { "▶ Start \($0)" } ?? "▶ Start",
                                      tint: Theme.blue, height: 34, bold: true)
                        }
                        .accessibilityLabel(startLabel(hero))
                        Button(intent: CompleteItemIntent(itemID: hero.id.uuidString)) {
                            PillLabel(text: "✓ Done", tint: W.mint, height: 34, bold: true)
                        }
                        .accessibilityLabel("Mark \(hero.title) done")
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: (geo.size.width - 12) * 0.6, height: geo.size.height, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 6) {
                    ListHeader(title: listTitle, count: rest.count)
                    if rest.isEmpty {
                        Text("Nothing else right now.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    ForEach(rest.prefix(3)) { item in
                        NowRow(item: item, date: entry.date, size: 12.5, buttonSize: 28, showsDone: false)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Large: act on top (60%), the rest of now below (40%)

    private func large(hero: WidgetSnapshot.Entry, rest: [WidgetSnapshot.Entry]) -> some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("RIGHT NOW").font(.nogTitle(15)).tracking(1.6)
                        Spacer(minLength: 6)
                        Link(destination: captureURL!) { TakeANogLabel(height: 34) }
                            .frame(width: 150)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Link(destination: itemURL(hero.id)!) {
                            VStack(alignment: .leading, spacing: 3) {
                                HeroDetail(item: hero, date: entry.date, size: 10.5)
                                Text(hero.title).font(.system(size: 19, weight: .semibold)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if hero.subTotal > 0 {
                                    Text("\(hero.subDone) of \(hero.subTotal) sub-nogs done")
                                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Button(intent: StartDoingIntent(itemID: hero.id.uuidString)) {
                                PillLabel(text: BoxFormat.short(hero.suggestedMinutes).map { "▶ Start · \($0)" } ?? "▶ Start",
                                          tint: Theme.blue, height: 44, bold: true)
                            }
                            .accessibilityLabel(startLabel(hero))
                            Button(intent: CompleteItemIntent(itemID: hero.id.uuidString)) {
                                PillLabel(text: "✓ Done", tint: W.mint, height: 44, bold: true)
                            }
                            .accessibilityLabel("Mark \(hero.title) done")
                            if hero.start != nil {
                                Button(intent: SnoozeItemIntent(itemID: hero.id.uuidString)) {
                                    PillLabel(text: "Later", tint: Theme.muted, height: 44).frame(width: 72)
                                }
                                .accessibilityLabel("Remind me about \(hero.title) later")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(W.heroFill))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(W.dot(for: hero, at: entry.date).opacity(0.55), lineWidth: 1.5))
                }
                .frame(height: geo.size.height * 0.6)

                VStack(alignment: .leading, spacing: 6) {
                    ListHeader(title: listTitle, count: rest.count)
                    if rest.isEmpty {
                        Text("Nothing else right now.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    ForEach(rest.prefix(3)) { item in
                        NowRow(item: item, date: entry.date, size: 14, buttonSize: 30, showsDone: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .frame(height: geo.size.height * 0.4, alignment: .top)
            }
        }
    }

    /// "ALSO NOW", or the chosen lists when they're not about now ("ALSO · LOOSE NOGS").
    private var listTitle: String {
        let config = entry.configuration
        if config.listKinds == [.now] && (config.nogs ?? []).isEmpty
            && (config.tag.map { WidgetPicker.cleanTag($0).isEmpty } ?? true) {
            return "ALSO NOW"
        }
        return "ALSO · \(config.label.uppercased())"
    }

    private func startLabel(_ item: WidgetSnapshot.Entry) -> String {
        if let box = item.suggestedMinutes { return "Start \(item.title) for \(IntervalLabel.amount(box))" }
        return "Start \(item.title)"
    }
}

/// "NOGGING SINCE 8:10 AM · ~10 MIN", "TODAY 3:00 PM", "LOOSE NOG".
private struct HeroDetail: View {
    let item: WidgetSnapshot.Entry
    let date: Date
    let size: CGFloat

    var body: some View {
        Text(text).font(W.label(size)).tracking(1.4)
            .foregroundStyle(W.dot(for: item, at: date))
            .lineLimit(1).minimumScaleFactor(0.8)
    }

    private var text: String {
        var parts: [String] = []
        if item.isDream {
            parts.append("DREAM NOG")
        } else if item.isNogging(at: date), let start = item.start {
            parts.append((item.alarm ? "ALARM SINCE " : "NOGGING SINCE ") + Self.moment(start, from: date))
        } else if let when = item.when(at: date) {
            let day = Calendar.current.isDate(when, inSameDayAs: date) ? "TODAY " : ""
            parts.append(day + Self.moment(when, from: date))
        } else {
            parts.append("LOOSE NOG")
        }
        if let box = item.suggestedMinutes { parts.append("~\(IntervalLabel.amount(box).uppercased())") }
        return parts.joined(separator: " · ")
    }

    /// A time today, otherwise a short date.
    static func moment(_ when: Date, from date: Date) -> String {
        Calendar.current.isDate(when, inSameDayAs: date)
            ? when.formatted(date: .omitted, time: .shortened).uppercased()
            : when.formatted(.dateTime.month(.abbreviated).day()).uppercased()
    }
}

private struct ListHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(W.label(10)).tracking(1.8).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 { Text("\(count)").font(.nogMeta).foregroundStyle(Theme.muted) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One nog in the list: its dot and title (opens it), ▶︎ to start, and ✓ on the large size.
private struct NowRow: View {
    let item: WidgetSnapshot.Entry
    let date: Date
    let size: CGFloat
    let buttonSize: CGFloat
    let showsDone: Bool

    var body: some View {
        HStack(spacing: 8) {
            Link(destination: itemURL(item.id)!) {
                HStack(spacing: 6) {
                    Circle().fill(W.dot(for: item, at: date)).frame(width: 7, height: 7)
                    Text(item.title).font(.system(size: size)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: buttonSize)
                .contentShape(Rectangle())
            }
            StartButton(entry: item, height: buttonSize, compact: true)
            if showsDone {
                Button(intent: CompleteItemIntent(itemID: item.id.uuidString)) {
                    CircleLabel(systemImage: "checkmark", tint: W.mint, size: buttonSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(item.title) done")
            }
        }
    }
}

/// "+ Take a Nog": opens New Nog with the keyboard up.
private struct TakeANogLabel: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus").font(.system(size: 12, weight: .bold))
            Text("Take a Nog").font(.system(size: 13.5, weight: .semibold))
        }
        .foregroundStyle(Theme.pink)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.pink.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.pink.opacity(0.7), lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Take a Nog")
        .accessibilityHint("Opens Nog to add something new")
    }
}

// MARK: Buttons

/// ▶︎ with the timebox ("▶ 15m"); starts the nog without opening the app.
private struct StartButton: View {
    let entry: WidgetSnapshot.Entry
    var height: CGFloat = 28
    var compact = false

    var body: some View {
        Button(intent: StartDoingIntent(itemID: entry.id.uuidString)) {
            if compact {
                CircleLabel(systemImage: "play.fill", tint: Theme.blue, size: height)
            } else {
                Text(BoxFormat.short(entry.suggestedMinutes).map { "▶ \($0)" } ?? "▶")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 10)
                    .frame(height: height)
                    .overlay(Capsule().strokeBorder(Theme.blue.opacity(0.6), lineWidth: 1.5))
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start \(entry.title)")
    }
}

private struct CircleLabel: View {
    let systemImage: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(tint.opacity(0.7), lineWidth: 1.5))
            .contentShape(Circle())
    }
}

/// Outlined, never filled, like the app's buttons.
private struct PillLabel: View {
    var text: String? = nil
    var systemImage: String? = nil
    let tint: Color
    var height: CGFloat = 34
    var bold = false

    var body: some View {
        Group {
            if let text {
                Text(text).font(.system(size: 13, weight: bold ? .semibold : .regular))
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11))
            }
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.7), lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                Text("▶ \(entry.lockTitle(item).uppercased())")
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).widgetAccentable()
                timerLine(item)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if !entry.nogging.isEmpty {
                Text("NOGGING NOW").font(.system(size: 11, weight: .semibold)).widgetAccentable()
                ForEach(entry.nogging.prefix(2)) { item in
                    Text("· \(entry.lockTitle(item))").font(.system(size: 13)).lineLimit(1)
                }
            } else if let next = entry.nextNog, let when = next.when(at: entry.date) {
                Text("NEXT NOG · \(when.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).widgetAccentable()
                Text(entry.lockTitle(next)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let detail = detail(next) {
                    Text(detail).font(.system(size: 11)).lineLimit(1)
                }
            } else {
                Text("NOGITIVITY").font(.system(size: 11, weight: .semibold)).widgetAccentable()
                Text("Nothing nogging").font(.system(size: 14, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(entry.doing.flatMap { itemURL($0.id) })
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

#Preview("Pick", as: .systemMedium) {
    NogitivityWidget()
} timeline: {
    NogitivityEntry(date: .now, snapshot: .sample(), configuration: NogitivityConfiguration())
}

#Preview("Pick, large", as: .systemLarge) {
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
