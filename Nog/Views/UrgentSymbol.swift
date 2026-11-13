import SwiftUI

/// The radiation trefoil: a dot in the middle and three blades, each a 60° slice of a ring,
/// one pointing down and two up at the sides. Fills its frame (a square works best).
struct TrefoilShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addEllipse(in: CGRect(x: c.x - r * 0.18, y: c.y - r * 0.18, width: r * 0.36, height: r * 0.36))
        let inner = r * 0.3
        // Degrees clockwise from 3 o'clock (y points down): lower, upper-left, upper-right.
        for middle in [90.0, 210.0, 330.0] {
            let start = Angle.degrees(middle - 30), end = Angle.degrees(middle + 30)
            var blade = Path()
            blade.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
            blade.addArc(center: c, radius: inner, startAngle: end, endAngle: start, clockwise: true)
            blade.closeSubpath()
            path.addPath(blade)
        }
        return path
    }
}

/// Nog's urgent mark. Off: the trefoil in outline, in `offColor`. On: filled with a
/// synthwave gradient (pink core to violet) and an atomic glow, pink inside a wider teal
/// halo. Low stimulation leaves the glow off (nogGlow), so on is still filled and pink.
struct UrgentSymbol: View {
    var isOn: Bool = true
    var size: CGFloat = 20
    var offColor: Color = .primary
    var glows: Bool = true
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        let side = size * scale
        Group {
            if isOn {
                TrefoilShape()
                    .fill(RadialGradient(colors: [Theme.pink, Theme.violet],
                                         center: .center, startRadius: 0, endRadius: side * 0.55))
                    .overlay {
                        TrefoilShape().stroke(Theme.pink.opacity(0.9), lineWidth: max(0.75, side / 24))
                    }
                    .nogGlow(color: glows ? Theme.pink.opacity(0.85) : .clear, radius: glows ? side * 0.18 : 0)
                    .nogGlow(color: glows ? Theme.teal.opacity(0.55) : .clear, radius: glows ? side * 0.45 : 0)
            } else {
                TrefoilShape()
                    .stroke(offColor, style: StrokeStyle(lineWidth: max(1, side / 14), lineJoin: .round))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 24) {
        UrgentSymbol(isOn: false)
        UrgentSymbol(isOn: true)
        UrgentSymbol(isOn: true, size: 11)
    }
    .padding(40)
    .background(Theme.base)
}
