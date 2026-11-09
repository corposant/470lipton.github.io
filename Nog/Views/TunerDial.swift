import SwiftUI

/// A radio-tuner style time picker: a glowing pro-app readout over a wide, recessed
/// scale you drag sideways. It has momentum, settles on a 5-minute mark and clicks
/// (haptics) as it passes each step.
///
/// Two modes:
/// - `minutes`: a time of day that wraps round the clock (quiet hours, "morning").
/// - `date`: a real moment. Rolling past midnight moves to the next day, forever;
///   rolling back stops at `notBefore` with a soft rubber band.
///
/// Performance: the scale is drawn in one Canvas pass (only visible ticks), the
/// settle animation interpolates a single value, and the result is written once,
/// when the dial comes to rest.
struct TimeTuner: View {
    var title: String = ""
    var step = 5
    /// Horizontal points per step.
    var spacing: CGFloat = 13

    /// Current committed value, in minutes from the reference midnight.
    private let value: Double
    private let commit: (Double) -> Void
    /// Lowest allowed value (nil = no limit).
    private let lower: Double?
    private let reference: Date?

    @State private var live: Double?
    @State private var dragStart: Double?

    /// Time of day, wrapping round the clock.
    init(minutes: Binding<Int>, title: String = "") {
        self.title = title
        value = Double(minutes.wrappedValue)
        commit = { minutes.wrappedValue = TimeTuner.wrap(Int($0.rounded())) }
        lower = nil
        reference = nil
    }

    /// A moment in time: rolls across days, never earlier than `notBefore`.
    init(date: Binding<Date>, title: String = "", notBefore: Date? = nil) {
        self.title = title
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: date.wrappedValue)
        reference = midnight
        value = date.wrappedValue.timeIntervalSince(midnight) / 60
        commit = { minutes in date.wrappedValue = midnight.addingTimeInterval(minutes * 60) }
        lower = notBefore.map { floor in
            // The first 5-minute mark at or after `notBefore`.
            let m = floor.timeIntervalSince(midnight) / 60
            return (m / 5).rounded(.up) * 5
        }
    }

    private var shown: Double { live ?? value }

    var body: some View {
        TunerFace(value: shown, title: title, step: step, spacing: spacing, reference: reference)
            .contentShape(Rectangle())
            .gesture(drag)
            .sensoryFeedback(.selection, trigger: Self.snapped(shown, step: step))
            .sensoryFeedback(.impact(weight: .light), trigger: isAtLowerStop)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title.isEmpty ? "Time" : title)
            .accessibilityValue(TunerFace.readout(for: shown, step: step, reference: reference).joined(separator: ", "))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(clamped(value + Double(step)))
                case .decrement: commit(clamped(value - Double(step)))
                @unknown default: break
                }
            }
    }

    private var isAtLowerStop: Bool {
        guard let lower else { return false }
        return shown <= lower + 0.5
    }

    private func clamped(_ v: Double) -> Double {
        guard let lower else { return v }
        return max(lower, v)
    }

    /// Past the lower stop, the dial resists (rubber band) instead of moving freely.
    private func rubberBanded(_ v: Double) -> Double {
        guard let lower, v < lower else { return v }
        return lower - (lower - v) * 0.25
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { gesture in
                let start = dragStart ?? shown
                dragStart = start
                // Dragging the scale left moves time forward, like turning a tuner.
                live = rubberBanded(start - Double(gesture.translation.width / spacing) * Double(step))
            }
            .onEnded { gesture in
                let start = dragStart ?? shown
                let projected = start - Double(gesture.predictedEndTranslation.width / spacing) * Double(step)
                let target = clamped((projected / Double(step)).rounded() * Double(step))
                dragStart = nil
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                    live = target
                } completion: {
                    commit(target)
                    live = nil
                }
            }
    }

    static func wrap(_ m: Int) -> Int { ((m % 1440) + 1440) % 1440 }

    static func snapped(_ v: Double, step: Int) -> Int { Int((v / Double(step)).rounded()) }
}

/// The drawing: readout + scale. Animatable, so the settle spring animates the
/// digits and the scale together, frame by frame.
private struct TunerFace: View, Animatable {
    var value: Double
    let title: String
    let step: Int
    let spacing: CGFloat
    /// Midnight the value counts from (date mode), or nil (time of day).
    let reference: Date?

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        VStack(spacing: 10) {
            readout
            scale
        }
    }

    // MARK: Readout

    private var readout: some View {
        let parts = Self.readout(for: value, step: step, reference: reference)
        let time = parts[0]
        let day = parts.count > 1 ? parts[1] : nil
        return VStack(alignment: .leading, spacing: 2) {
            if !title.isEmpty || day != nil {
                PanelLabel(text: [title, day].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            }
            GlowReadout(text: time, size: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .recessedWell(cornerRadius: 9)
    }

    /// [time, day?]: e.g. ["9:30 PM", "Tomorrow"].
    static func readout(for value: Double, step: Int, reference: Date?) -> [String] {
        let snapped = Int((value / Double(step)).rounded()) * step
        guard let reference else { return [timeString(TimeTuner.wrap(snapped))] }
        let date = reference.addingTimeInterval(Double(snapped) * 60)
        return [date.formatted(date: .omitted, time: .shortened), DayFormat.label(date)]
    }

    // MARK: Scale

    private var scale: some View {
        Canvas { context, size in
            let mid = size.width / 2
            let visibleSteps = Int(size.width / spacing / 2) + 2
            let center = value / Double(step)
            let first = Int(center.rounded(.down)) - visibleSteps
            let last = Int(center.rounded(.up)) + visibleSteps

            for i in first...last {
                let m = i * step
                let x = mid + CGFloat(Double(i) - center) * spacing
                // Fade toward the edges, like a scale wrapping round a drum.
                let distance = abs(x - mid) / mid
                let fade = max(0, 1 - pow(distance, 1.6))
                let wrapped = TimeTuner.wrap(m)
                let isMidnight = wrapped == 0
                let isHour = wrapped % 60 == 0
                let isQuarter = wrapped % 15 == 0
                let height: CGFloat = isMidnight ? 30 : (isHour ? 22 : (isQuarter ? 14 : 8))
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 6))
                tick.addLine(to: CGPoint(x: x, y: size.height - 6 - height))
                context.stroke(tick,
                               with: .color((isMidnight && reference != nil ? Theme.violet : Color(white: 0.75))
                                                .opacity((isHour ? 0.85 : 0.45) * fade)),
                               lineWidth: isHour ? 1.6 : 1)
                if isHour {
                    let text: String
                    if isMidnight, let reference {
                        // Midnight shows the day you're rolling into.
                        let day = reference.addingTimeInterval(Double(m) * 60)
                        text = day.formatted(.dateTime.weekday(.abbreviated)).uppercased()
                    } else {
                        text = Self.hourLabel(wrapped)
                    }
                    let label = Text(text)
                        .font(.custom("Futura-Medium", size: 11))
                        .foregroundColor((isMidnight && reference != nil ? Theme.violet : Color(white: 0.8)).opacity(fade))
                    context.draw(label, at: CGPoint(x: x, y: 12), anchor: .center)
                }
            }

            // The fixed needle: starts below the hour labels so it never covers one,
            // with a small pointer at the top.
            var needle = Path()
            needle.move(to: CGPoint(x: mid, y: 22))
            needle.addLine(to: CGPoint(x: mid, y: size.height - 2))
            var pointer = Path()
            pointer.move(to: CGPoint(x: mid - 4, y: 0))
            pointer.addLine(to: CGPoint(x: mid + 4, y: 0))
            pointer.addLine(to: CGPoint(x: mid, y: 6))
            pointer.closeSubpath()
            context.addFilter(.shadow(color: Theme.pink.opacity(0.9), radius: 5))
            context.stroke(needle, with: .color(Theme.pink), lineWidth: 2)
            context.fill(pointer, with: .color(Theme.pink))
        }
        .frame(height: 58)
        .padding(.horizontal, 6)
        .recessedWell(cornerRadius: 10)
        .drawingGroup()
    }

    // MARK: Formatting

    static func timeString(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func hourLabel(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }
}

/// An inset dark panel, like the Logic transport display.
struct RecessedWell: View {
    var cornerRadius: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.027, green: 0.03, blue: 0.043),
                                          Color(red: 0.05, green: 0.06, blue: 0.08)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.black.opacity(0.95), .white.opacity(0.09)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
    }
}

extension View {
    /// Sits on a dark recessed well. The well is always dark, so its contents use
    /// dark-mode colours (light-mode text colours would be unreadable on it).
    func recessedWell(cornerRadius: CGFloat = 9) -> some View {
        background(RecessedWell(cornerRadius: cornerRadius))
            .environment(\.colorScheme, .dark)
    }
}

/// A settings row that shows its time glowing and opens a tuner when tapped.
struct TimeTunerRow: View {
    let title: String
    @Binding var minutes: Int
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isOpen.toggle() }
            } label: {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    Text(TunerFace.timeString(minutes))
                        .nogReadout(15)
                        .foregroundStyle(Theme.lcd)
                        .shadow(color: Theme.blue.opacity(0.5), radius: 4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .recessedWell(cornerRadius: 7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                TimeTuner(minutes: $minutes)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
