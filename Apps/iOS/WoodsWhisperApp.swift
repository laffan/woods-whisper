import SwiftUI
import AppIntents
import WoodsWhisperKit
#if canImport(UIKit)
import UIKit
#endif

@main
struct WoodsWhisperApp: App {
    @StateObject private var model = AppModel()
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        WW.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .tint(WW.moss)
                .task {
                    WoodsWhisperShortcuts.updateAppShortcutParameters()
                    await model.loadDownloadedModelsAtStartup()
                    // Seed the Watch's record-target picker once the session has had time to activate.
                    model.syncDocumentsToWatch()
                }
        }
    }
}

#if canImport(UIKit)
/// Minimal app delegate whose only job is to answer the system's supported-orientation query from
/// the "Allow Rotation" setting. SwiftUI has no first-class orientation lock, so the interface
/// orientations are gated here and re-evaluated on demand via `AppDelegate.applyOrientationLock()`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask {
        AppSettings.shared.allowRotation ? .all : .portrait
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    /// Re-evaluate the supported orientations after the setting changes, snapping the window back to
    /// portrait when rotation was just disabled.
    @MainActor
    static func applyOrientationLock() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationLock)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif

// The design system lives in this file (rather than its own) so an already-generated
// Xcode project picks it up without an xcodegen regen.

// MARK: - Woods Whisper design system
//
// A quiet, editorial "field notes" look shared by every iOS screen:
//   • warm paper backgrounds (deep pine-black in dark mode) instead of system grouped gray,
//   • a single moss-green accent in place of the default blue,
//   • ember red reserved for recording and destructive moments,
//   • clean sans-serif type throughout, small tracked-uppercase section labels,
//   • flat lists with hairline separators, and floating panes with hairline strokes
//     instead of system materials.
//
// Everything visual routes through here so the palette and type stay consistent.

enum WW {

    // MARK: Palette

    /// App background — warm paper in light mode, near-black pine in dark.
    static let paper = dynamicColor(light: UIColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1),
                                    dark: UIColor(red: 0.086, green: 0.094, blue: 0.078, alpha: 1))

    /// Raised surfaces: sheets, panes, settings rows.
    static let surface = dynamicColor(light: UIColor(red: 0.996, green: 0.992, blue: 0.984, alpha: 1),
                                      dark: UIColor(red: 0.122, green: 0.133, blue: 0.114, alpha: 1))

    /// Primary text.
    static let ink = dynamicColor(light: UIColor(red: 0.129, green: 0.122, blue: 0.102, alpha: 1),
                                  dark: UIColor(red: 0.918, green: 0.910, blue: 0.875, alpha: 1))

    /// Secondary text — meta lines, footers, captions.
    static let inkSecondary = dynamicColor(light: UIColor(red: 0.467, green: 0.455, blue: 0.420, alpha: 1),
                                           dark: UIColor(red: 0.592, green: 0.580, blue: 0.541, alpha: 1))

    /// Tertiary text and inactive glyphs.
    static let inkTertiary = dynamicColor(light: UIColor(red: 0.659, green: 0.643, blue: 0.600, alpha: 1),
                                          dark: UIColor(red: 0.416, green: 0.408, blue: 0.376, alpha: 1))

    /// Hairline rules and separators.
    static let hairline = dynamicColor(light: UIColor(red: 0.890, green: 0.878, blue: 0.839, alpha: 1),
                                       dark: UIColor(red: 0.169, green: 0.180, blue: 0.157, alpha: 1))

    /// The one accent: moss green (lighter sage in dark mode for contrast).
    static let moss = dynamicColor(light: UIColor(red: 0.247, green: 0.361, blue: 0.267, alpha: 1),
                                   dark: UIColor(red: 0.576, green: 0.675, blue: 0.549, alpha: 1))

    /// Recording / destructive: a muted ember red.
    static let ember = dynamicColor(light: UIColor(red: 0.737, green: 0.322, blue: 0.251, alpha: 1),
                                    dark: UIColor(red: 0.851, green: 0.439, blue: 0.357, alpha: 1))

    /// Attention / pending states: muted ochre.
    static let amber = dynamicColor(light: UIColor(red: 0.725, green: 0.541, blue: 0.184, alpha: 1),
                                    dark: UIColor(red: 0.812, green: 0.655, blue: 0.333, alpha: 1))

    /// Supporting hue for edit-ish actions and the transfer log category: muted slate blue.
    static let slate = dynamicColor(light: UIColor(red: 0.353, green: 0.478, blue: 0.553, alpha: 1),
                                    dark: UIColor(red: 0.545, green: 0.655, blue: 0.729, alpha: 1))

    /// Supporting hue for transform-ish actions and the model log category: muted violet.
    static let violet = dynamicColor(light: UIColor(red: 0.494, green: 0.435, blue: 0.596, alpha: 1),
                                     dark: UIColor(red: 0.647, green: 0.588, blue: 0.745, alpha: 1))

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // MARK: Type

    /// Body font for document text.
    static let bodyText = Font.system(size: 17)

    /// Row titles (document names and the like).
    static let rowTitle = Font.system(size: 17, weight: .semibold)

    /// Small tracked-uppercase label font (pairs with `.tracking(1.4)` and `.textCase(.uppercase)`).
    static let sectionLabel = Font.system(size: 11, weight: .semibold)

    // MARK: Global chrome

    /// One-shot UIKit appearance pass: flatten the navigation and tab bars onto the paper
    /// background — no blur, no shadow — with ink titles and moss/muted item colors.
    static func configureAppearance() {
        #if canImport(UIKit)
        let paperUI = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.086, green: 0.094, blue: 0.078, alpha: 1)
            : UIColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1) }
        let inkUI = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.918, green: 0.910, blue: 0.875, alpha: 1)
            : UIColor(red: 0.129, green: 0.122, blue: 0.102, alpha: 1) }
        let mossUI = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.576, green: 0.675, blue: 0.549, alpha: 1)
            : UIColor(red: 0.247, green: 0.361, blue: 0.267, alpha: 1) }
        let mutedUI = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.416, green: 0.408, blue: 0.376, alpha: 1)
            : UIColor(red: 0.659, green: 0.643, blue: 0.600, alpha: 1) }
        let hairlineUI = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.169, green: 0.180, blue: 0.157, alpha: 1)
            : UIColor(red: 0.890, green: 0.878, blue: 0.839, alpha: 1) }

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = paperUI
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                                   .foregroundColor: inkUI]
        nav.largeTitleTextAttributes = [.font: UIFont.systemFont(ofSize: 32, weight: .bold),
                                        .foregroundColor: inkUI]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = paperUI
        tab.shadowColor = hairlineUI
        let itemFont = UIFont.systemFont(ofSize: 10, weight: .medium)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance,
                     tab.compactInlineLayoutAppearance] {
            item.selected.iconColor = mossUI
            item.selected.titleTextAttributes = [.foregroundColor: mossUI, .font: itemFont]
            item.normal.iconColor = mutedUI
            item.normal.titleTextAttributes = [.foregroundColor: mutedUI, .font: itemFont]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        #endif
    }

}

// MARK: - List styling

extension View {
    /// The standard content list treatment: flat rows on the paper background with no
    /// system grouping chrome. (Grouped style rather than plain so section headers stay
    /// transparent instead of picking up a sticky material background.)
    func wwList() -> some View {
        self
            .listStyle(.grouped)
            .listSectionSpacing(20)
            .scrollContentBackground(.hidden)
            .background(WW.paper)
    }

    /// The standard settings-form treatment: grouped cards on paper, drawn on the
    /// `surface` color via per-section `.listRowBackground(WW.surface)`.
    func wwForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(WW.paper)
    }

    /// Standard flat-list row: transparent background, hairline separator.
    func wwRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(WW.hairline)
    }
}

// MARK: - Section header

/// A small tracked-uppercase section label — the app's replacement for stock list headers.
struct WWSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(WW.sectionLabel)
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(WW.inkSecondary)
    }
}

/// A quiet footer note for settings sections.
struct WWFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(WW.inkTertiary)
    }
}

// MARK: - Empty state

/// A minimal empty state: a thin-stroked circle around a light glyph, a title, and a
/// short secondary message. Replaces `ContentUnavailableView`.
struct WWEmptyState: View {
    let title: String
    let systemImage: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(WW.inkTertiary)
                .frame(width: 64, height: 64)
                .overlay(Circle().stroke(WW.hairline, lineWidth: 1))
            Text(title)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(WW.ink)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(WW.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Floating pane

extension View {
    /// The floating bottom pane treatment shared by the Transform and Move panes: a surface
    /// card with a hairline stroke and a soft shadow instead of system material.
    func wwPane() -> some View {
        self
            .background(WW.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(WW.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 24, y: 8)
    }
}

// MARK: - Hairline

/// A 1-pixel horizontal rule in the theme hairline color.
struct WWHairline: View {
    var body: some View {
        Rectangle()
            .fill(WW.hairline)
            .frame(height: 1)
    }
}

// MARK: - Round icon button (recorder controls)

/// Circular recorder control. `fill` draws a solid ember/moss disc with paper glyph;
/// otherwise a hairline-stroked ring with an ink glyph.
struct WWRoundIconButtonStyle: ButtonStyle {
    var diameter: CGFloat = 56
    var fill: Color? = nil
    var glyphColor: Color? = nil

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.34, weight: .medium))
            .foregroundStyle(glyphColor ?? (fill == nil ? WW.ink : .white))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(fill ?? Color.clear))
            .overlay(Circle().stroke(fill == nil ? WW.hairline : Color.clear, lineWidth: 1))
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
