import SwiftUI
import UIKit

/// Calm mode: fewer things that move, glow or buzz.
///
/// - **Reduce Motion** (iOS setting) or **Low stimulation** (Nog setting): changes happen
///   without springs or slides, and views appear with a fade instead of moving in.
/// - **Low stimulation** also turns off glows, the background haze and grid, and haptics.
/// - **Haptics** can be turned off on its own.
///
/// Use `withNogAnimation`, `.nogAnimation`, `.nogFeedback`, `.nogGlow` and
/// `AnyTransition.nog` instead of the plain SwiftUI versions so all of this applies everywhere.
enum Calm {
    static let lowStimulationKey = "lowStimulation"
    static let hapticsKey = "hapticsEnabled"

    /// The Low stimulation setting (off by default).
    static var lowStimulation: Bool { UserDefaults.standard.bool(forKey: lowStimulationKey) }

    /// Haptics play only when they're on and Low stimulation is off.
    static var hapticsOn: Bool {
        (UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true) && !lowStimulation
    }

    /// Reduce Motion or Low stimulation.
    @MainActor static var reducesMotion: Bool { UIAccessibility.isReduceMotionEnabled || lowStimulation }

    /// `animation`, or none when motion should be reduced.
    @MainActor static func animation(_ animation: Animation?) -> Animation? {
        reducesMotion ? nil : animation
    }
}

/// `withAnimation` that respects Reduce Motion and Low stimulation.
@MainActor @discardableResult
func withNogAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Calm.animation(animation), body)
}

/// `withAnimation(_:completionCriteria:_:completion:)` that respects Reduce Motion and
/// Low stimulation. With motion reduced the change happens at once and `completion`
/// runs straight after it.
@MainActor @discardableResult
func withNogAnimation<Result>(_ animation: Animation? = .default,
                              completionCriteria: AnimationCompletionCriteria = .logicallyComplete,
                              _ body: () throws -> Result,
                              completion: @escaping () -> Void) rethrows -> Result {
    guard let animation = Calm.animation(animation) else {
        let result = try body()
        completion()
        return result
    }
    return try withAnimation(animation, completionCriteria: completionCriteria, body, completion: completion)
}

extension AnyTransition {
    /// `transition`, or a plain fade when motion should be reduced.
    @MainActor static func nog(_ transition: AnyTransition) -> AnyTransition {
        Calm.reducesMotion ? .opacity : transition
    }
}

private struct CalmAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Calm.lowStimulationKey) private var lowStimulation = false
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion || lowStimulation ? nil : animation, value: value)
    }
}

private struct CalmGlow: ViewModifier {
    @AppStorage(Calm.lowStimulationKey) private var lowStimulation = false
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.shadow(color: lowStimulation ? .clear : color, radius: radius)
    }
}

extension View {
    /// `.animation(_:value:)` that respects Reduce Motion and Low stimulation.
    func nogAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(CalmAnimation(animation: animation, value: value))
    }

    /// A coloured glow (a shadow), left off in Low stimulation.
    func nogGlow(color: Color, radius: CGFloat) -> some View {
        modifier(CalmGlow(color: color, radius: radius))
    }

    /// `.sensoryFeedback` that stays quiet when haptics are off or Low stimulation is on.
    func nogFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { _, _ in Calm.hapticsOn }
    }

    func nogFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T,
                                   condition: @escaping (_ oldValue: T, _ newValue: T) -> Bool) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { old, new in Calm.hapticsOn && condition(old, new) }
    }
}
