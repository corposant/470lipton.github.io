import SwiftUI

/// The little send-off when a nog is completed: a short puff of confetti from the Complete
/// button, in the app's synth colours, that falls and fades in about a second.
///
/// Kept small on purpose (about three dozen bits, no flashing, no sound) so it feels like an
/// occasion without being a lot. With Reduce Motion or Low stimulation nothing flies: a still
/// check seal fades in instead (see `CompleteSeal`).
struct ConfettiPuff: View {
    /// Where the puff starts, in this view's own coordinates.
    let origin: CGPoint
    /// How long a bit lives, start to faded out.
    static let lifetime: TimeInterval = 1.0

    @State private var start = Date.now
    @State private var bits: [Bit] = Bit.burst(count: 36)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, _ in
                guard t < Self.lifetime + 0.1 else { return }
                for bit in bits {
                    draw(bit, at: t, in: &context)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let gravity: Double = 520
    private static let drag: Double = 2.2

    private func draw(_ bit: Bit, at time: TimeInterval, in context: inout GraphicsContext) {
        let t = max(0, time - bit.delay)
        guard t > 0 else { return }
        // Thrown out fast, slowed by the air, then pulled down: a puff rather than a fountain.
        let slow = (1 - exp(-Self.drag * t)) / Self.drag
        let x = origin.x + bit.velocity.dx * slow + sin(t * bit.wobble) * 6
        let y = origin.y + bit.velocity.dy * slow + 0.5 * Self.gravity * t * t
        let life = t / (Self.lifetime - bit.delay)
        guard life < 1 else { return }
        // Full strength at first, then fades over the last half of its life.
        let alpha = life < 0.5 ? 1 : max(0, 1 - (life - 0.5) / 0.5)
        // Starts small, as if out of the button, and opens up.
        let grow = min(1, 0.35 + t * 5)

        var c = context
        c.opacity = alpha
        c.translateBy(x: x, y: y)
        c.rotate(by: .radians(bit.spin * t + bit.angle))
        // A tumble: the bit turns edge-on and back, like paper.
        c.scaleBy(x: grow * cos(t * bit.flip), y: grow)
        c.fill(bit.shape.path(size: bit.size), with: .color(bit.color))
    }

    struct Bit {
        enum Kind: CaseIterable {
            case strip, dot, hex

            func path(size: CGFloat) -> Path {
                switch self {
                case .strip:
                    return Path(roundedRect: CGRect(x: -size / 2, y: -size / 4.5, width: size, height: size / 2.25),
                                cornerRadius: size / 9)
                case .dot:
                    return Path(ellipseIn: CGRect(x: -size / 3, y: -size / 3, width: size / 1.5, height: size / 1.5))
                case .hex:
                    // A tiny honeycomb cell, like the background.
                    let r = size / 2.4
                    var p = Path()
                    for i in 0..<6 {
                        let a = Double(i) * .pi / 3
                        let pt = CGPoint(x: r * cos(a), y: r * sin(a))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    p.closeSubpath()
                    return p
                }
            }
        }

        var velocity: CGVector
        var size: CGFloat
        var color: Color
        var shape: Kind
        var angle: Double
        var spin: Double
        var flip: Double
        var wobble: Double
        var delay: Double

        static let palette: [Color] = [Theme.pink, Theme.violet, Theme.blue, Theme.teal, ProgressRing.complete]

        static func burst(count: Int) -> [Bit] {
            (0..<count).map { i in
                // Mostly up and out, a few sideways; never straight down into the button.
                let angle = Double.random(in: (-.pi * 0.95)...(-.pi * 0.05))
                let speed = Double.random(in: 260...620)
                return Bit(
                    velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                    size: .random(in: 7...11),
                    color: palette[i % palette.count],
                    shape: Kind.allCases[i % Kind.allCases.count],
                    angle: .random(in: 0...(2 * .pi)),
                    spin: .random(in: -9...9),
                    flip: .random(in: 5...11),
                    wobble: .random(in: 3...7),
                    delay: .random(in: 0...0.08))
            }
        }
    }
}

/// The calm version of the send-off: a check in a ring that fades in where you tapped, and holds
/// still. Used instead of confetti with Reduce Motion or Low stimulation.
struct CompleteSeal: View {
    let origin: CGPoint
    @State private var shown = false
    @ScaledMetric(relativeTo: .title) private var side: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(Theme.glass)
            Circle().strokeBorder(ProgressRing.complete, lineWidth: 2)
            Image(systemName: "checkmark")
                .font(.system(size: side * 0.4, weight: .bold))
                .foregroundStyle(ProgressRing.complete)
        }
        .frame(width: side, height: side)
        .position(origin)
        .opacity(shown ? 1 : 0)
        // A fade is fine with Reduce Motion: nothing moves or grows.
        .animation(.easeOut(duration: 0.25), value: shown)
        .onAppear { shown = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
