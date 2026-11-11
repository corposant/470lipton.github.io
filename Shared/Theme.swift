import SwiftUI
import UIKit

// "Cream Soda + Sunset Glass".
// Dark: deep synthwave indigo, a magenta and cyan haze, clear glass panels with a faint pink edge.
// Light: soft vanilla cream with warm brown greys and slightly deeper accents.
//
// Typography uses fonts built into iOS, so there's nothing to license or bundle:
//   • Futura    titles, section labels, dial and panel labels: geometric, mid-century
//   • SF Pro    body text (system default)
//   • SF Mono   readouts: timers, times, intervals

enum Theme {
    // Accents. Light-mode values are dark enough for text (WCAG AA, 4.5:1 or better on the
    // base and on glass); Increase Contrast swaps in stronger ones (7:1 or better).
    // Normal values are 5.5:1 or better on the base and the glass; Increase Contrast ones 7.5:1 or better.
    static let pink = Color(light: 0xA8265C, dark: 0xFF74C8, highLight: 0x8A1A4A, highDark: 0xFFA3DB)
    static let violet = Color(light: 0x6440BE, dark: 0xBC9BFF, highLight: 0x4E2E9E, highDark: 0xD4BFFF)
    static let blue = Color(light: 0x1D5CA3, dark: 0x62C9FF, highLight: 0x154883, highDark: 0xA0DDFF)

    /// Pink → violet → blue: thin lines and outlines only, never big fills.
    static let synth = LinearGradient(colors: [pink, violet, blue], startPoint: .leading, endPoint: .trailing)

    // Surfaces
    static let base = Color(light: 0xF6EEDF, dark: 0x140E26)
    static let baseTop = Color(light: 0xFBF5EA, dark: 0x1F1238)
    /// Frosted panel fill (sits on top of a material). More solid with Increase Contrast.
    static let glass = Color(uiColor: UIColor { t in
        let high = t.accessibilityContrast == .high
        return t.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: high ? 0.12 : 0.07) : UIColor(hex: 0xFFFBF3, alpha: high ? 0.88 : 0.62) })
    /// Hairline edges: a faint pink glow on the dark glass, warm brown on cream.
    static let edge = Color(uiColor: UIColor { t in
        let high = t.accessibilityContrast == .high
        return t.userInterfaceStyle == .dark
            ? UIColor(hex: high ? 0xFFC8F0 : 0xFF8CDC, alpha: high ? 0.40 : 0.16)
            : UIColor(hex: 0x5A3C1E, alpha: high ? 0.32 : 0.10) })
    static let edgeStrong = Color(uiColor: UIColor { t in
        let high = t.accessibilityContrast == .high
        return t.userInterfaceStyle == .dark
            ? UIColor(hex: high ? 0xFFD2F2 : 0xFFA0E6, alpha: high ? 0.55 : 0.30)
            : UIColor(hex: 0x5A3C1E, alpha: high ? 0.45 : 0.22) })
    /// Secondary text. 5:1 or better on the base and glass in both modes.
    static let muted = Color(light: 0x6E5D4E, dark: 0xAFA3CC, highLight: 0x4E4136, highDark: 0xCEC4E6)

    /// Tiny labels inside panels and on the dark recessed wells.
    static let panelLabel = Color(light: 0x6E5D4E, dark: 0xAFA3CC, highLight: 0x4E4136, highDark: 0xCEC4E6)

    /// Lit "LCD" digits: pale blue on the dark wells, a readable blue on a light background.
    static let lcd = Color(light: 0x1D5CA3, dark: 0xCFE9FF, highLight: 0x154883, highDark: 0xE6F4FF)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Adds Increase Contrast variants (Settings → Accessibility → Display & Text Size).
    init(light: UInt32, dark: UInt32, highLight: UInt32, highDark: UInt32) {
        self.init(uiColor: UIColor { t in
            let high = t.accessibilityContrast == .high
            if t.userInterfaceStyle == .dark { return UIColor(hex: high ? highDark : dark) }
            return UIColor(hex: high ? highLight : light)
        })
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
    /// Grows and shrinks with the person's text size, like the nearest system text style.
    static func nogTitle(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let bold = weight == .bold || weight == .heavy || weight == .black
        return .custom(bold ? "Futura-Bold" : "Futura-Medium", size: size, relativeTo: .nearest(to: size))
    }

    /// Futura, small caps-style section labels. Scales with text size.
    static let nogLabel = Font.custom("Futura-Medium", size: 12, relativeTo: .caption)

    /// Futura, tiny labels inside panels and displays. Scales with text size.
    /// 11 pt is the smallest size Apple recommends.
    static let nogMicroLabel = Font.custom("Futura-Medium", size: 11, relativeTo: .caption2)

    /// SF Mono at a fixed size. It does NOT scale with text size, so in the app use the
    /// `.nogReadout(_:)` view modifier instead; this stays for widgets with fixed layouts.
    static func nogReadout(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// SF Mono, small meta lines ("TIMEBOX 25 MIN · #WRITING"). 11 pt by default; scales with text size.
    static let nogMeta = Font.system(.caption2, design: .monospaced, weight: .medium)
}

extension Font.TextStyle {
    /// The system text style whose default size is closest to `size`, so a custom font
    /// at that size scales the way that style does.
    static func nearest(to size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: .caption2
        case ..<12.5: .caption
        case ..<14: .footnote
        case ..<15.5: .subheadline
        case ..<16.5: .callout
        case ..<18.5: .body
        case ..<21: .title3
        case ..<25: .title2
        case ..<31: .title
        default: .largeTitle
        }
    }
}

/// A fixed design size that follows the person's text size setting (Dynamic Type).
/// `maxScale` caps the growth: big readouts and icons in fixed frames grow less,
/// so a 44 pt timer doesn't push everything off screen.
struct ScaledSystemFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var maxScale: CGFloat = 3

    func body(content: Content) -> some View {
        content.font(.system(size: NogScale.value(size, for: typeSize, maxScale: maxScale), weight: weight, design: design))
    }
}

/// A frame that grows with text size (at most 1.6×), for icons and buttons that hold scaled text.
struct ScaledFrame: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let width: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        content.frame(width: NogScale.value(width, for: typeSize, maxScale: 1.6),
                      height: NogScale.value(height, for: typeSize, maxScale: 1.6))
    }
}

enum NogScale {
    /// `size` scaled the way body text scales at `typeSize`, capped at `maxScale` times.
    static func value(_ size: CGFloat, for typeSize: DynamicTypeSize, maxScale: CGFloat) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: traits)
        return min(scaled, size * maxScale)
    }
}

extension View {
    /// SF Mono readout (timers, times, intervals) that scales with text size.
    /// Readouts of 28 pt and up grow at most 1.6×.
    func nogReadout(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: .monospaced, maxScale: size >= 28 ? 1.6 : 3))
    }

    /// A system font at a design size that scales with text size. Mostly used for SF Symbols
    /// sitting in fixed shapes, so it grows at most 1.6× (pair it with `nogFrame`).
    func nogFont(_ size: CGFloat, weight: Font.Weight = .regular, maxScale: CGFloat = 1.6) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, maxScale: maxScale))
    }

    /// A fixed-size frame (an icon circle, a round button) that grows with text size, at most 1.6×.
    func nogFrame(width: CGFloat, height: CGFloat) -> some View {
        modifier(ScaledFrame(width: width, height: height))
    }

    /// One line normally; up to `accessibilityLines` at the accessibility text sizes,
    /// so long titles wrap instead of being cut off.
    func nogLineLimit(_ lines: Int = 1, accessibilityLines: Int = 3) -> some View {
        modifier(AdaptiveLineLimit(lines: lines, accessibilityLines: accessibilityLines))
    }
}

struct AdaptiveLineLimit: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let lines: Int
    let accessibilityLines: Int

    func body(content: Content) -> some View {
        content.lineLimit(typeSize.isAccessibilitySize ? accessibilityLines : lines)
    }
}

// MARK: - Building blocks

/// "DOING NOW 02 ────" label with a trailing hairline. The hairline is the same
/// length on every heading, so it reads as one mark, not a leftover that shrinks
/// as the title grows.
struct SectionLabel: View {
    let title: String
    var count: Int? = nil
    var tint: Color = Theme.muted
    @ScaledMetric(relativeTo: .caption) private var ruleLength: CGFloat = 56

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.nogLabel)
                .tracking(2.2)
                .foregroundStyle(tint)
            if let count {
                Text(String(format: "%02d", count))
                    .font(.nogMeta)
                    .foregroundStyle(Theme.muted)
            }
            LinearGradient(colors: [Theme.edgeStrong, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: ruleLength, height: 1)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.leading, -4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Tiny spaced Futura caps for labels inside recessed panels ("NEXT NOG · TODAY").
struct PanelLabel: View {
    let text: String
    var tint = Theme.panelLabel

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
            .nogGlow(color: Theme.violet.opacity(0.18), radius: 14)
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
            .nogFont(size * 0.38, weight: .bold)
            .foregroundStyle(tint)
            .nogFrame(width: size, height: size)
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
    static let complete = Color(light: 0x137046, dark: 0x6FE3A8)

    var body: some View {
        let f = min(1, max(0, fraction))
        let color = f >= 1 ? Self.complete : tint
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: f)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .nogGlow(color: color.opacity(0.5), radius: 2)
        }
        .padding(lineWidth / 2)
        .nogAnimation(.snappy, value: f)
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

extension EnvironmentValues {
    /// The accent of the tab a view sits in (see `nogTabTheme`). NogBackground tints its
    /// top haze with it; nil (widgets, sheets) keeps the usual blue.
    @Entry var nogAccent: Color? = nil
}

/// Indigo (or cream) with a haze top-right in the tab's accent (blue by default), a warm haze
/// lower-left (magenta at night, apricot by day) and a faint display grid.
struct NogBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nogAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(Calm.lowStimulationKey) private var lowStimulation = false

    /// Increase Contrast, Reduce Transparency or Low stimulation: a plain base, no haze or grid.
    private var isPlain: Bool { contrast == .increased || reduceTransparency || lowStimulation }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.baseTop, Theme.base], startPoint: .top, endPoint: .bottom)
            if !isPlain { haze }
        }
        .ignoresSafeArea()
    }

    private var haze: some View {
        ZStack {
            RadialGradient(colors: [(accent ?? Theme.blue).opacity(scheme == .dark ? 0.20 : 0.12), .clear],
                           center: UnitPoint(x: 0.9, y: 0.05), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [scheme == .dark ? Color(UIColor(hex: 0xFF50AA)).opacity(0.15)
                                                    : Color(UIColor(hex: 0xE8965A)).opacity(0.14), .clear],
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
                context.stroke(path, with: .color(scheme == .dark ? .white.opacity(0.025) : Color(UIColor(hex: 0x5A3C1E)).opacity(0.035)), lineWidth: 1)
            }
        }
    }
}
