import SwiftUI
import UIKit

// Each tab has its own accent: the page title, buttons and toggles, and the soft haze in
// the background all take it on. The accent is only ever a hint of where you are. Every
// tab is also named in its title and on the tab bar, so nothing depends on seeing colour.

extension Theme {
    /// The Map tab's accent. 4.5:1 or better on the base in light mode, 9:1 in dark;
    /// Increase Contrast swaps in 7:1 or better.
    static let teal = Color(light: 0x00736B, dark: 0x3DD6C6, highLight: 0x005A54, highDark: 0x8AEBE0)
}

extension AppTab {
    /// Settings › Advanced › Map tab. Off for new installs; existing ones keep it.
    static let mapTabKey = "showMapTab"

    /// The page title, which matches the tab bar label.
    var title: String {
        switch self {
        case .capture: "New Nog"
        case .agenda: "Agenda"
        case .nogs: "List"
        case .map: "Map"
        }
    }

    var accent: Color {
        switch self {
        case .capture: Theme.pink
        case .agenda: Theme.violet
        case .nogs: Theme.blue
        case .map: Theme.teal
        }
    }
}

extension View {
    /// A tab's colours: its accent for buttons, toggles and the background haze.
    /// Put it on the tab's NavigationStack so pages pushed onto the stack keep them.
    func nogTabTheme(_ tab: AppTab) -> some View {
        tint(tab.accent)
            .environment(\.nogAccent, tab.accent)
    }

    /// The tab's title in Futura, in its accent. Put it on the stack's root page (inside the
    /// NavigationStack, so it can reach the bar); pushed pages share the same bar.
    /// `title` replaces the tab's name for a while (e.g. "3 selected").
    func nogTabTitle(_ tab: AppTab, title: String? = nil) -> some View {
        navigationTitle(title ?? tab.title)
            .background { NavigationTitleStyler(color: tab.accent) }
    }
}

// MARK: Settings

/// The gear that opens Settings. Every tab shows it in the same place, the top-right
/// corner: tabs with a navigation bar use `SettingsToolbarItem` (last in their toolbar,
/// so it's always the rightmost), and the Map, which hides its bar, ends its header row
/// with this. RootView owns the sheet, so there's one Settings, whichever tab opens it.
struct SettingsButton: View {
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
    }
}

/// The Settings gear for a tab's navigation bar. Put it last in the toolbar.
struct SettingsToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
    }
}

/// The app's navigation title fonts: Futura Bold for large titles, Futura Medium inline.
/// Both scale with the person's text size (Dynamic Type), capped so long titles still fit.
enum NogTitleFont {
    static func large(_ traits: UITraitCollection? = nil) -> UIFont {
        let base = UIFont(name: "Futura-Bold", size: 32) ?? .systemFont(ofSize: 30, weight: .bold)
        return UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: base, maximumPointSize: 52, compatibleWith: traits)
    }

    static func inline(_ traits: UITraitCollection? = nil) -> UIFont {
        let base = UIFont(name: "Futura-Medium", size: 17) ?? .systemFont(ofSize: 16, weight: .semibold)
        return UIFontMetrics(forTextStyle: .headline).scaledFont(for: base, maximumPointSize: 26, compatibleWith: traits)
    }

    static func attributes(large: Bool, color: UIColor?, traits: UITraitCollection? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = large
            ? [.font: Self.large(traits), .kern: 1.5]
            : [.font: Self.inline(traits), .kern: 1.0]
        if let color { attributes[.foregroundColor] = color }
        return attributes
    }

    /// The app-wide default, for any navigation bar no tab styles (set once at launch).
    static func applyDefault() {
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = attributes(large: true, color: nil)
        bar.titleTextAttributes = attributes(large: false, color: nil)
    }
}

/// Sets the title fonts and colour on the navigation bar of the stack it sits in.
/// SwiftUI has no per-stack title styling, so this reaches the UIKit bar directly.
private struct NavigationTitleStyler: UIViewControllerRepresentable {
    let color: Color?
    // Read so SwiftUI updates the bar when light/dark, Increase Contrast or text size change.
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        // Resolved for the current appearance: UIKit gets a plain colour, never a dynamic one.
        controller.color = color.map { UIColor(Color($0.resolve(in: context.environment))) }
        controller.apply()
    }

    final class Controller: UIViewController {
        var color: UIColor?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            // Text size changes: rebuild the fonts at the new size.
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Controller, _) in
                self.apply()
            }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        func apply() {
            guard let bar = navigationController?.navigationBar else { return }
            let traits = traitCollection
            func styled(_ appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
                appearance.largeTitleTextAttributes = NogTitleFont.attributes(large: true, color: color, traits: traits)
                appearance.titleTextAttributes = NogTitleFont.attributes(large: false, color: color, traits: traits)
                return appearance
            }
            // Copies keep whatever background the bar already has; only the titles change.
            bar.standardAppearance = styled(bar.standardAppearance.copy())
            bar.compactAppearance = styled((bar.compactAppearance ?? bar.standardAppearance).copy())
            let edge = bar.scrollEdgeAppearance?.copy() ?? {
                let transparent = UINavigationBarAppearance()
                transparent.configureWithTransparentBackground()
                return transparent
            }()
            bar.scrollEdgeAppearance = styled(edge)
            bar.compactScrollEdgeAppearance = styled((bar.compactScrollEdgeAppearance ?? edge).copy())
        }
    }
}
