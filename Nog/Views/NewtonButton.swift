import SwiftUI

/// How a Newton-style button is drawn: a rounded rectangle, tight to its label, with an
/// outline in its tint. The tag button's drawer is drawn from the same look, so when it
/// opens the button's own outline stretches out into the drawer.
struct NewtonLook {
    var fill: Color
    var stroke: Color
    var foreground: Color
    var lineWidth: CGFloat = 1.5
    var cornerRadius: CGFloat = 12
    /// Filled with its colour (the main action), rather than outlined.
    var isFilled = false

    /// A button that's on (or always coloured, like Done on the Map card): tinted outline,
    /// a light wash of the tint, tinted label.
    static func tinted(_ tint: Color) -> NewtonLook {
        NewtonLook(fill: tint.opacity(0.10), stroke: tint.opacity(0.7), foreground: tint)
    }

    /// A button that's off: a neutral outline and an ordinary label.
    static var plain: NewtonLook {
        NewtonLook(fill: .clear, stroke: Theme.edgeStrong, foreground: Color.primary.opacity(0.85), lineWidth: 1)
    }

    /// The one main action: filled with the tint, label in the background colour.
    static func prominent(_ tint: Color) -> NewtonLook {
        NewtonLook(fill: tint, stroke: tint, foreground: Theme.base, isFilled: true)
    }

    /// A button whose panel is open: the tint a little stronger.
    static func open(_ tint: Color) -> NewtonLook {
        NewtonLook(fill: tint.opacity(0.18), stroke: tint, foreground: tint)
    }

    /// `tinted` when on, `plain` when off.
    static func chip(_ tint: Color, isOn: Bool) -> NewtonLook {
        isOn ? .tinted(tint) : .plain
    }

    var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// Nog's Newton-style button. Pressed, it inverts: filled with its colour, label in the
/// background colour, the way Newton's buttons answered a tap. 38pt tall to look compact,
/// but it takes taps a few points beyond its edge so the target is 44pt.
struct NewtonButtonStyle: ButtonStyle {
    var look: NewtonLook
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ look: NewtonLook) { self.look = look }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        // Pressed, the colours swap. A filled button turns to paper with a coloured label.
        let fill = pressed ? (look.isFilled ? Theme.base : look.foreground) : look.fill
        let label = pressed ? (look.isFilled ? look.stroke : Theme.base) : look.foreground
        // Increase Contrast: a firmer outline in the label's own colour.
        let stroke = contrast == .increased ? (look.isFilled ? look.stroke : look.foreground) : look.stroke
        configuration.label
            .lineLimit(1)
            .foregroundStyle(label)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(fill, in: look.shape)
            .overlay(look.shape.strokeBorder(stroke, lineWidth: contrast == .increased ? max(look.lineWidth, 2) : look.lineWidth))
            .contentShape(.interaction, look.shape.inset(by: -3))
            .contentShape(.hoverEffect, look.shape)
    }
}

extension ButtonStyle where Self == NewtonButtonStyle {
    /// Nog's Newton-style button in `look`.
    static func newton(_ look: NewtonLook) -> NewtonButtonStyle { NewtonButtonStyle(look) }
}
