import SwiftUI

/// A radio-tuner style time picker: a glowing pro-app readout over a wide, recessed
/// scale you drag sideways. It has momentum, settles on a 5-minute mark, clicks
/// (haptics) as it passes each step, and wraps around midnight.
///
/// Performance: the scale is drawn in one Canvas pass (only visible ticks), the
/// settle animation interpolates a single value, and the binding is written once,
/// when the dial comes to rest.
struct TimeTuner: View {
    /// Minutes after midnight.
    @Binding var minutes: Int
    var title: String = ""
    var step = 5
    /// Horizontal points per step.
    var spacing: CGFloat = 13

    /// The value being shown while dragging or settling (nil = the binding's value).
    @State private var live: Double?
    @State private var dragStart: Double?

    private var shown: Double { live ?? Double(minutes) }

    var body: some View {
        TunerFace(value: shown, title: title, step: step, spacing: spacing)
            .contentShape(Rectangle())
            .gesture(drag)
            .sensoryFeedback(.selection, trigger: Self.snapped(shown, step: step))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title.isEmpty ? "Time" : title)
            .accessibilityValue(TunerFace.timeString(Self.wrap(Int(shown.rounded()))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: minutes = Self.wrap(minutes + step)
                case .decrement: minutes = Self.wrap(minutes - step)
                @unknown default: break
                }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? shown
                dragStart = start
                // Dragging the scale left moves time forward, like turning a tuner.
                live = start - Double(value.translation.width / spacing) * Double(step)
            }
            .onEnded { value in
                let start = dragStart ?? shown
                let projected = start - Double(value.predictedEndTranslation.width / spacing) * Double(step)
                let target = (projected / Double(step)).rounded() * Double(step)
                dragStart = nil
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                    live = target
                } completion: {
                    minutes = Self.wrap(Int(target))
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
        let text = Self.timeString(TimeTuner.wrap(Int((value / Double(step)).rounded()) * step))
        return VStack(alignment: .leading, spacing: 2) {
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.nogMicroLabel)
                    .tracking(1.8)
                    .foregroundStyle(Color(red: 0.36, green: 0.42, blue: 0.5))
            }
            ZStack(alignment: .leading) {
                Text(Self.ghost(for: text)).foregroundStyle(Theme.blue.opacity(0.07))
                Text(text)
                    .foregroundStyle(Color(red: 0.75, green: 0.89, blue: 1.0))
                    .shadow(color: Theme.blue.opacity(0.55), radius: 8)
                    .shadow(color: Theme.blue.opacity(0.9), radius: 1)
            }
            .font(.nogReadout(40))
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RecessedWell(cornerRadius: 9))
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
                let isHour = wrapped % 60 == 0
                let isQuarter = wrapped % 15 == 0
                let height: CGFloat = isHour ? 22 : (isQuarter ? 14 : 8)
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 6))
                tick.addLine(to: CGPoint(x: x, y: size.height - 6 - height))
                context.stroke(tick,
                               with: .color(Color(white: 0.75).opacity((isHour ? 0.85 : 0.45) * fade)),
                               lineWidth: isHour ? 1.6 : 1)
                if isHour {
                    let label = Text(Self.hourLabel(wrapped))
                        .font(.custom("Futura-Medium", size: 11))
                        .foregroundColor(Color(white: 0.8).opacity(fade))
                    context.draw(label, at: CGPoint(x: x, y: 12), anchor: .center)
                }
            }

            // The fixed needle.
            var needle = Path()
            needle.move(to: CGPoint(x: mid, y: 2))
            needle.addLine(to: CGPoint(x: mid, y: size.height - 2))
            context.addFilter(.shadow(color: Theme.pink.opacity(0.9), radius: 5))
            context.stroke(needle, with: .color(Theme.pink), lineWidth: 2)
        }
        .frame(height: 58)
        .padding(.horizontal, 6)
        .background(RecessedWell(cornerRadius: 10))
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

    /// Unlit "8" segments behind each digit; other characters stay as they are.
    static func ghost(for text: String) -> String {
        String(text.map { $0.isNumber ? "8" : $0 })
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
                        .font(.nogReadout(15))
                        .foregroundStyle(Color(red: 0.75, green: 0.89, blue: 1.0))
                        .shadow(color: Theme.blue.opacity(0.5), radius: 4)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RecessedWell(cornerRadius: 7))
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
