import SwiftUI

/// A skeuomorphic rotary selector for an item's state: Open · Doing · Dream · Nogged.
/// Twist the knob: it clicks past each position and settles into the nearest one.
struct StatusDial: View {
    let status: ItemStatus
    let onSelect: (ItemStatus) -> Void

    /// Knob diameter.
    var knobSize: CGFloat = 92

    @State private var dragAngle: Double?
    /// Finger angle at the last drag update, to turn by the change (not jump to the finger).
    @State private var lastTouchAngle: Double?

    /// Detent positions, in degrees clockwise from straight up.
    static let stops: [(status: ItemStatus, angle: Double)] = [
        (.open, -105), (.doing, -35), (.someday, 35), (.done, 105),
    ]

    /// Side labels sit further out so they clear the knob and the scale.
    private func labelRadius(_ degrees: Double) -> CGFloat {
        knobSize * 0.5 + (abs(degrees) > 60 ? 60 : 34)
    }
    private var size: CGSize { CGSize(width: knobSize + 200, height: knobSize + 46) }
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
                // Only the knob itself responds to touch.
                .contentShape(Circle())
                .gesture(turn)
                .position(center)
        }
        .frame(width: size.width, height: size.height)
        .nogFeedback(.selection, trigger: lit)
        .nogAnimation(.spring(response: 0.35, dampingFraction: 0.7), value: status)
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
            .nogGlow(color: isLit ? tint.opacity(0.8) : .clear, radius: 6)
            .fixedSize()
            .position(x: center.x + sin(a) * labelRadius(degrees), y: center.y - cos(a) * labelRadius(degrees))
            .allowsHitTesting(false)
    }

    // MARK: Turning

    /// Twist to turn: the knob rotates by how far your finger travels around its centre,
    /// so grabbing it never makes it jump. Settles into the nearest position on release.
    private var turn: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                let c = CGPoint(x: knobSize / 2, y: knobSize / 2)
                let dx = value.location.x - c.x
                let dy = value.location.y - c.y
                // Too close to the centre, the angle is jittery: wait for a clearer twist.
                guard dx * dx + dy * dy > 64 else { return }
                let touch = atan2(dx, -dy) * 180 / .pi
                let current = dragAngle ?? Self.angle(for: status)
                if let last = lastTouchAngle {
                    var step = touch - last
                    if step > 180 { step -= 360 } else if step < -180 { step += 360 }
                    dragAngle = min(120, max(-120, current + step))
                } else {
                    dragAngle = current
                }
                lastTouchAngle = touch
            }
            .onEnded { _ in
                if let angle = dragAngle {
                    let chosen = Self.nearest(to: angle)
                    if chosen != status { onSelect(chosen) }
                }
                lastTouchAngle = nil
                withNogAnimation(.spring(response: 0.35, dampingFraction: 0.65)) { dragAngle = nil }
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
        case .done: Color(light: 0x137046, dark: 0x6FE3A8)
        }
    }

    static func summary(_ status: ItemStatus) -> String {
        switch status {
        case .open: "On your plate. Nogs you on schedule."
        case .doing: "You're on it. Timer running, nogs paused."
        case .someday: "Parked in Someday. No reminders."
        case .done: "Finished. Kept for reference."
        }
    }
}

/// A pro-app knob, after Final Cut / Logic / Aperture: a glossy graphite dome sitting in a
/// recessed well, with a crisp bevel, a soft specular highlight and a glowing indicator.
private struct Knob: View {
    let angle: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                // Recessed well the knob sits in (darker, with an inner shadow).
                Circle()
                    .fill(Color(white: 0.06))
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(colors: [.black.opacity(0.9), .white.opacity(0.10)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.5))

                // Shadow the dome casts into the well.
                Circle()
                    .fill(.black.opacity(0.6))
                    .padding(d * 0.09)
                    .blur(radius: 4)
                    .offset(y: 3)

                // Graphite dome.
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.36), Color(white: 0.20), Color(white: 0.13)],
                                         center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: d * 0.5))
                    .padding(d * 0.09)

                // Very fine grip grooves, barely there.
                Circle()
                    .strokeBorder(Color.black.opacity(0.25), style: StrokeStyle(lineWidth: d * 0.035, dash: [1, 3]))
                    .padding(d * 0.1)
                    .rotationEffect(.degrees(angle))

                // Bevel: lit from above, shaded below.
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.06), .black.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.2)
                    .padding(d * 0.09)

                // Soft specular highlight across the top of the dome.
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: d * 0.6, height: d * 0.34)
                    .offset(y: -d * 0.2)

                // Indicator.
                Capsule()
                    .fill(tint)
                    .frame(width: d * 0.045, height: d * 0.17)
                    .nogGlow(color: tint, radius: 3)
                    .nogGlow(color: tint.opacity(0.6), radius: 8)
                    .offset(y: -d * 0.27)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: d, height: d)
        }
    }
}
