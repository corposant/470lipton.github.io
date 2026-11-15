import AppIntents
import SwiftUI
import WidgetKit

/// A one-tap New Nog button for the Lock Screen, Control Center and the Action Button.
/// Tapping it unlocks (if needed) and opens Nog with the capture field focused.
struct NewNogControl: ControlWidget {
    static let kind = "NewNogControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                // The title is what VoiceOver reads and what shows under the button
                // in Control Center, so it names the result, not the gesture.
                // nog.carton is a custom symbol (Assets.xcassets): controls only draw
                // SF Symbols or custom symbols, not plain images like Carton.imageset.
                Label("New Nog", image: "nog.carton")
                    // Shown on the Action Button and spoken when it is pressed.
                    .controlWidgetActionHint("New Nog")
            }
        }
        // Shown in the controls gallery when someone adds or swaps a control.
        .displayName("New Nog")
        .description("Open Nog ready to type a new nog.")
    }
}
