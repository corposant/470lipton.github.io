import SwiftUI
import UIKit

// "Dark Side": charcoal + frosted glass + synthwave pink/blue, outlined controls.
// Light mode keeps the same accents on a cool, pale-gray base.
//
// Typography uses fonts built into iOS, so there's nothing to license or bundle:
//   • Futura    titles, section labels, dial and panel labels: geometric, mid-century
//   • SF Pro    body text (system default)
//   • SF Mono   readouts: timers, times, intervals

enum Theme {
    // Accents
    static let pink = Color(light: 0xD93A86, dark: 0xFF5FB0)
    static let violet = Color(light: 0x7656DB, dark: 0xA17BFF)
    static let blue = Color(light: 0x1C7ED6, dark: 0x4FB3FF)

    /// Pink → violet → blue: thin lines and outlines only, never big fills.
    static let synth = LinearGradient(colors: [pink, violet, blue], startPoint: .leading, endPoint: .trailing)

    // Surfaces
    static let base = Color(light: 0xF1F2F6, dark: 0x15161C)
    static let baseTop = Color(light: 0xE7E9F0, dark: 0x1C1D25)
    /// Frosted panel fill (sits on top of a material).
    static let glass = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.045) : UIColor(white: 1, alpha: 0.55) })
    static let edge = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08) })
    static let edgeStrong = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 0, alpha: 0.14) })
    static let muted = Color(light: 0x6B6F84, dark: 0x9296AB)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Font {
    /// Futura, for titles. Bold and heavier weights use Futura Bold, the rest Futura Medium.
    static func nogTitle(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let bold = weight == .bold || weight == .heavy || weight == .black
        return .custom(bold ? "Futura-Bold" : "Futura-Medium", size: size)
    }

    /// Futura, small caps-style section labels.
    static let nogLabel = Font.custom("Futura-Medium", size: 11.5)

    /// Futura, tiny labels inside panels and displays.
    static let nogMicroLabel = Font.custom("Futura-Medium", size: 9)

    /// SF Mono, for timers and readouts.
    static func nogReadout(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// SF Mono, small meta lines ("TIMEBOX 25 MIN · #WRITING").
    static let nogMeta = Font.system(size: 11, weight: .medium, design: .monospaced)
}

// MARK: - Building blocks

/// "DOING NOW 02 ────────" label with a trailing hairline.
struct SectionLabel: View {
    let title: String
    var count: Int? = nil
    var tint: Color = Theme.muted

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.nogLabel)
                .tracking(2.2)
                .foregroundStyle(tint)
            if let count {
                Text(String(format: "%02d", count))
                    .font(.nogMeta)
                    .foregroundStyle(Theme.muted.opacity(0.7))
            }
            LinearGradient(colors: [Theme.edgeStrong, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
        .textCase(nil)
        .padding(.leading, -4)
    }
}

/// Tiny spaced Futura caps for labels inside recessed panels ("NEXT NOG · TODAY").
struct PanelLabel: View {
    let text: String
    var tint = Color(red: 0.54, green: 0.58, blue: 0.64)

    var body: some View {
        Text(text.uppercased())
            .font(.nogMicroLabel)
            .tracking(1.8)
            .foregroundStyle(tint)
    }
}

/// Colored outline, no fill. Tints faintly while pressed.
struct OutlineButtonStyle: ButtonStyle {
    var tint: Color = Theme.blue
    var expands = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(tint.opacity(configuration.isPressed ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.7), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// Outline in the pink→blue gradient, for the one most important action on a screen.
struct GradientOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nogTitle(13))
            .tracking(2)
            .foregroundStyle(.primary)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(Theme.violet.opacity(configuration.isPressed ? 0.12 : 0.0),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.synth, lineWidth: 1.5))
            .shadow(color: Theme.violet.opacity(0.18), radius: 14)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Small outlined circle, e.g. the row ▶︎. With `progress`, the outline becomes a ring
/// that fills clockwise from the top (sub-items done), turning green when complete.
struct CircleOutlineIcon: View {
    let systemName: String
    var tint: Color = Theme.blue
    var size: CGFloat = 30
    /// 0…1, or nil for a plain outline.
    var progress: Double? = nil

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .overlay {
                if let progress {
                    ProgressRing(fraction: progress, tint: tint, lineWidth: 2.5)
                } else {
                    Circle().strokeBorder(tint.opacity(0.75), lineWidth: 1)
                }
            }
            .contentShape(Circle())
    }
}

/// A thin ring: a faint track with the done part drawn over it, clockwise from the top.
struct ProgressRing: View {
    let fraction: Double
    var tint: Color = Theme.blue
    var lineWidth: CGFloat = 2.5

    /// Mint, like Nogged.
    static let complete = Color(light: 0x1E9E62, dark: 0x6FE3A8)

    var body: some View {
        let f = min(1, max(0, fraction))
        let color = f >= 1 ? Self.complete : tint
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: f)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 2)
        }
        .padding(lineWidth / 2)
        .animation(.snappy, value: f)
    }
}

extension View {
    /// Frosted panel with a hairline edge.
    func nogPanel(cornerRadius: CGFloat = 16) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.glass))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
        }
    }

    /// Frosted rows + themed background for List/Form screens.
    func nogListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background { NogBackground() }
    }
}

/// Charcoal with a blue haze top-right, a pink haze lower-left and a faint display grid.
struct NogBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.baseTop, Theme.base], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.blue.opacity(scheme == .dark ? 0.12 : 0.10), .clear],
                           center: UnitPoint(x: 0.9, y: 0.05), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Theme.pink.opacity(scheme == .dark ? 0.08 : 0.07), .clear],
                           center: UnitPoint(x: 0.05, y: 0.65), startRadius: 0, endRadius: 380)
            Canvas { context, size in
                var path = Path()
                let step: CGFloat = 24
                stride(from: 0, through: size.width, by: step).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: 0, through: size.height, by: step).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(scheme == .dark ? .white.opacity(0.018) : .black.opacity(0.025)), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
    }
}
