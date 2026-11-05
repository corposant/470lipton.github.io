import SwiftUI

/// A skeuomorphic rotary selector for an item's state: Open · Doing · Dream · Nogged.
/// Drag the knob (it clicks into each position) or tap a label.
struct StatusDial: View {
    let status: ItemStatus
    let onSelect: (ItemStatus) -> Void

    /// Knob diameter.
    var knobSize: CGFloat = 92

    @State private var dragAngle: Double?

    /// Detent positions, in degrees clockwise from straight up.
    static let stops: [(status: ItemStatus, angle: Double)] = [
        (.open, -105), (.doing, -35), (.someday, 35), (.done, 105),
    ]

    private var labelRadius: CGFloat { knobSize * 0.5 + 34 }
    private var size: CGSize { CGSize(width: knobSize + 150, height: knobSize + 74) }
    private var center: CGPoint { CGPoint(x: size.width / 2, y: knobSize * 0.5 + 34) }

    var body: some View {
        let angle = dragAngle ?? Self.angle(for: status)
        let lit = Self.nearest(to: angle)

        ZStack(alignment: .topLeading) {
            scale
            ForEach(Self.stops, id: \.status) { stop in
                label(stop.status, at: stop.angle, isLit: stop.status == lit)
            }
            Knob(angle: angle, tint: Self.tint(lit))
                .frame(width: knobSize, height: knobSize)
                .position(center)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(turn)
        .sensoryFeedback(.selection, trigger: lit)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: status)
        .accessibilityRepresentation {
            Picker("Status", selection: Binding(get: { status }, set: onSelect)) {
                ForEach(ItemStatus.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
    }

    // MARK: Parts

    /// Fine tick marks along the sweep, like an amp's volume scale.
    private var scale: some View {
        Canvas { context, _ in
            for i in 0...24 {
                let a = (-120 + Double(i) * 10) * .pi / 180
                let isMajor = Self.stops.contains { abs($0.angle - (-120 + Double(i) * 10)) < 6 }
                let r1 = knobSize * 0.5 + 8
                let r2 = r1 + (isMajor ? 9 : 5)
                var path = Path()
                path.move(to: CGPoint(x: center.x + sin(a) * r1, y: center.y - cos(a) * r1))
                path.addLine(to: CGPoint(x: center.x + sin(a) * r2, y: center.y - cos(a) * r2))
                context.stroke(path, with: .color(Theme.muted.opacity(isMajor ? 0.7 : 0.3)), lineWidth: isMajor ? 1.5 : 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func label(_ status: ItemStatus, at degrees: Double, isLit: Bool) -> some View {
        let a = degrees * .pi / 180
        let tint = Self.tint(status)
        return Text(status.label.uppercased())
            .font(.nogLabel)
            .tracking(1.4)
            .foregroundStyle(isLit ? tint : Theme.muted.opacity(0.75))
            .shadow(color: isLit ? tint.opacity(0.8) : .clear, radius: 6)
            .fixedSize()
            .position(x: center.x + sin(a) * labelRadius, y: center.y - cos(a) * labelRadius)
            .onTapGesture { onSelect(status) }
    }

    // MARK: Turning

    private var turn: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.location.x - center.x
                let dy = value.location.y - center.y
                guard dx * dx + dy * dy > 100 else { return } // ignore touches dead-centre
                let degrees = atan2(dx, -dy) * 180 / .pi
                dragAngle = min(120, max(-120, degrees))
            }
            .onEnded { _ in
                if let angle = dragAngle {
                    let chosen = Self.nearest(to: angle)
                    if chosen != status { onSelect(chosen) }
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) { dragAngle = nil }
            }
    }

    // MARK: Helpers

    static func angle(for status: ItemStatus) -> Double {
        stops.first { $0.status == status }?.angle ?? stops[0].angle
    }

    static func nearest(to angle: Double) -> ItemStatus {
        stops.min { abs($0.angle - angle) < abs($1.angle - angle) }!.status
    }

    static func tint(_ status: ItemStatus) -> Color {
        switch status {
        case .open: Theme.pink
        case .doing: Theme.blue
        case .someday: Theme.violet
        case .done: Color(light: 0x1E9E62, dark: 0x6FE3A8)
        }
    }

    static func summary(_ status: ItemStatus) -> String {
        switch status {
        case .open: "On your plate. Nogs you on schedule."
        case .doing: "You're on it. Timer running, nogs paused."
        case .someday: "Parked in Dream nogs. No nogs."
        case .done: "Finished. Kept for reference."
        }
    }
}

/// Brushed gunmetal knob with a knurled grip and a glowing LED pointer.
private struct Knob: View {
    let angle: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                // Shadow it casts on the panel.
                Circle()
                    .fill(.black.opacity(0.55))
                    .blur(radius: 8)
                    .offset(y: 5)

                // Knurled grip ring.
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.16)],
                                         startPoint: .top, endPoint: .bottom))
                Circle()
                    .strokeBorder(Color(white: 0.08).opacity(0.8),
                                  style: StrokeStyle(lineWidth: d * 0.07, dash: [1.4, 2.4]))
                    .padding(d * 0.015)
                    .rotationEffect(.degrees(angle))

                // Brushed-metal body.
                Circle()
                    .fill(AngularGradient(colors: [
                        Color(white: 0.30), Color(white: 0.47), Color(white: 0.24), Color(white: 0.52),
                        Color(white: 0.27), Color(white: 0.45), Color(white: 0.30),
                    ], center: .center))
                    .padding(d * 0.1)
                    .rotationEffect(.degrees(angle))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1).padding(d * 0.1))

                // Raised centre cap.
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.38), Color(white: 0.17)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: d * 0.32))
                    .padding(d * 0.24)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1).padding(d * 0.24))

                // LED pointer.
                Capsule()
                    .fill(tint)
                    .frame(width: d * 0.05, height: d * 0.2)
                    .shadow(color: tint, radius: 4)
                    .shadow(color: tint.opacity(0.7), radius: 9)
                    .offset(y: -d * 0.3)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: d, height: d)
        }
    }
}
