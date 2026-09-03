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

    /// The text size chosen in Settings → Display, read here and handed to the whole app as an
    /// environment value: every screen that draws transcription text — and every editor those
    /// blocks turn into — reads it from there, so changing it redraws all of them at once.
    @AppStorage(AppSettings.transcriptTextSizeKey)
    private var transcriptTextSize = AppSettings.defaultTranscriptTextSize

    init() {
        WW.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environment(\.transcriptTextSize, transcriptTextSize)
                .tint(WW.moss)
                .task {
                    WoodsWhisperShortcuts.updateAppShortcutParameters()
                    // Catch the backup folder up on anything that changed while it was unreachable
                    // (or before it was chosen). No-op when local backup is off.
                    model.documents.backUpNow()
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

    /// The ring around the record dot: black on paper, white on pine. Deliberately pure rather than
    /// drawn from the warm palette — it's there to hold the dot's edge against either background,
    /// which a softer ink wouldn't do.
    static let recordRing = dynamicColor(light: .black, dark: .white)

    /// Attention / pending states: muted ochre.
    static let amber = dynamicColor(light: UIColor(red: 0.725, green: 0.541, blue: 0.184, alpha: 1),
                                    dark: UIColor(red: 0.812, green: 0.655, blue: 0.333, alpha: 1))

    /// Supporting hue for edit-ish actions and the transfer log category: muted slate blue.
    static let slate = dynamicColor(light: UIColor(red: 0.353, green: 0.478, blue: 0.553, alpha: 1),
                                    dark: UIColor(red: 0.545, green: 0.655, blue: 0.729, alpha: 1))

    /// The ink behind a stored colour id — an Inbox tag's (`InboxTag.paletteIDs`), a graph node's or
    /// a group's (`GraphPalette.colorIDs`, the same set of names). The kit names these; the palette
    /// they name lives here, which is what keeps a colour right in both light and dark.
    ///
    /// Optional, because "no colour" is a real answer: a node without one is drawn as the plain card
    /// it has always been, rather than a green one.
    static func paletteColor(_ colorID: String?) -> Color? {
        switch colorID {
        case "moss":   return moss
        case "violet": return violet
        case "amber":  return amber
        case "slate":  return slate
        case "ember":  return ember
        case "ink":    return inkSecondary
        default:       return nil
        }
    }

    /// The same, for an Inbox tag, which always has one: an id nothing answers to falls back to the
    /// app's one accent.
    static func tagColor(_ colorID: String?) -> Color {
        paletteColor(colorID) ?? moss
    }

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

    // MARK: Measure

    /// The widest a column of content is allowed to get. Everything a screen reads down — lists,
    /// forms, floating panes, bottom bars — is held to this and centered, so an iPad shows a
    /// readable column rather than a line of text a foot wide. See `wwContentWidth()`.
    static let contentMaxWidth: CGFloat = 800

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
    ///
    /// The list is held to `wwContentWidth()` and the paper laid behind the whole width, so on an
    /// iPad the rows read as a centered column on paper rather than running edge to edge.
    func wwList() -> some View {
        self
            .listStyle(.grouped)
            .listSectionSpacing(20)
            .scrollContentBackground(.hidden)
            .wwContentWidth()
            .background(WW.paper)
    }

    /// The standard settings-form treatment: grouped cards on paper, drawn on the
    /// `surface` color via per-section `.listRowBackground(WW.surface)`.
    func wwForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .wwContentWidth()
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
    /// card with a hairline stroke and a soft shadow instead of system material, held to the
    /// content width so it doesn't stretch across an iPad.
    func wwPane() -> some View {
        self
            .background(WW.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(WW.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 24, y: 8)
            .frame(maxWidth: WW.contentMaxWidth)
    }
}

// MARK: - Haptics

/// The app's haptics, in one place.
///
/// Retained generators rather than a fresh one per event: the engine takes a moment to warm up, and
/// a generator created and released in the same breath tends to drop or delay its first tick —
/// which is exactly the tick that matters when it's confirming that a recording just began. So the
/// press that *might* become a recording primes it (`prepare`), and the moment capture actually
/// starts, `recordingStarted` fires into a warm engine.
@MainActor
enum WWHaptics {
    #if canImport(UIKit)
    /// A crisp tick — short and sharp, for "that happened", rather than the softer thud of a
    /// medium impact.
    private static let tick = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .light)
    private static let firm = UIImpactFeedbackGenerator(style: .medium)
    #endif

    /// Warm the engine for a tick that may be a fraction of a second away — a finger going down on
    /// something holdable, say. Cheap, and safe to call on every press.
    static func prepare() {
        #if canImport(UIKit)
        tick.prepare()
        #endif
    }

    /// Recording has begun: the one tick the hand is waiting for, since a hold gives no other sign
    /// that the app heard it.
    static func recordingStarted() {
        #if canImport(UIKit)
        tick.impactOccurred()
        tick.prepare()          // the next one is usually close behind (a chain, another node)
        #endif
    }

    /// Something small happened — a selection changed, a node settled.
    static func light() {
        #if canImport(UIKit)
        soft.impactOccurred()
        #endif
    }

    /// Something with more weight to it — a branch re-parented, a group drawn.
    static func medium() {
        #if canImport(UIKit)
        firm.impactOccurred()
        #endif
    }
}

// MARK: - Transcription text size

/// How big transcription text is set, in points — document paragraphs, Inbox transcripts, graph
/// nodes, and the in-place editors each of those becomes.
///
/// An environment value rather than a global read, so a change in Settings → Display invalidates
/// every view that draws such text instead of quietly taking effect on the next redraw. The app root
/// seeds it from `AppSettings.transcriptTextSize`; nothing else writes it.
private struct TranscriptTextSizeKey: EnvironmentKey {
    static let defaultValue: Double = AppSettings.defaultTranscriptTextSize
}

extension EnvironmentValues {
    var transcriptTextSize: Double {
        get { self[TranscriptTextSizeKey.self] }
        set { self[TranscriptTextSizeKey.self] = newValue }
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

// MARK: - Batch action bar (selection mode)

/// The bar of actions pinned below a list while it's in long-press selection mode — used by both
/// the Inbox (recordings) and Documents. Sits on a surface strip with a hairline above it; apply
/// `.disabled(...)` to the bar to grey out every action at once when nothing is selected.
struct WWBatchBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 16) {
            content
        }
        .padding()
        .wwContentWidth()          // the strip runs full width; its buttons don't
        .background(WW.surface)
        .overlay(alignment: .top) { WWHairline() }
    }
}

/// One action inside a `WWBatchBar`: a glyph over a caption, tinted moss (or ember when
/// destructive), sharing the bar's width evenly with its siblings.
struct WWBatchButton: View {
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String, _ systemImage: String, role: ButtonRole? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 17, weight: .regular))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(role == .destructive ? WW.ember : WW.moss)
    }
}

// MARK: - Inline edit box (in-line editing)

/// The box a piece of text is edited in, in place — an Inbox entry's transcript, or a paragraph in
/// a document. A moss-outlined card holding the editor itself with its own action bar beneath it,
/// inside the outline: the edit-mode actions as a compressed row of icons at the **left**, **Done**
/// at the **right**. Keeping the bar inside the outline is the point — what the actions apply to is
/// whatever the outline is drawn around.
struct WWInlineEditBox<Content: View, Actions: View>: View {
    let onDone: () -> Void
    /// Shows a spinner beside Done — on the right, so a transform running doesn't shuffle the
    /// icons on the left out from under your finger.
    var isWorking: Bool = false
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            WWHairline()
            HStack(spacing: 2) {
                actions
                Spacer(minLength: 10)
                if isWorking { ProgressView().controlSize(.small).padding(.trailing, 4) }
                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WW.moss)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .background(WW.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(WW.moss, lineWidth: 1.5))
    }
}

/// One icon in a `WWInlineEditBox`'s action row: glyph only (the name rides along as its
/// accessibility label), so several actions fit in the box's bottom-left corner without crowding
/// Done. Kept compact — a graph node's editor carries five of these across a 280-point card.
struct WWInlineEditAction: View {
    let title: String
    let systemImage: String
    var enabled: Bool = true
    /// The ink. Green by default; a destructive action passes the ember, since a trash can that
    /// looks like everything beside it is a trash can somebody taps by accident.
    var tint: Color = WW.moss
    let action: () -> Void

    init(_ title: String, _ systemImage: String, enabled: Bool = true, tint: Color = WW.moss,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.enabled = enabled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(title)
    }
}

// MARK: - Content width

extension View {
    /// Hold content to a comfortable reading width and center it. An iPad's full width is far too
    /// wide for a column of prose — and it puts a bar's two ends a hand-span apart — so lists,
    /// forms, panes and bars all pass through here. A no-op on iPhone, which is narrower than the
    /// cap to begin with.
    func wwContentWidth() -> some View {
        self
            .frame(maxWidth: WW.contentMaxWidth)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Record button & round icon controls

/// The app's one "start recording" control: a plain red dot, centered above the bottom bar of the
/// Inbox and of a document. It replaces the mic that used to sit in the toolbar — the thing you do
/// most often shouldn't be the smallest target on the screen.
///
/// Nothing behind it: no plate, no shadow, no glyph. It floats over the text, which scrolls past
/// underneath — held to its own edge by a thin ring (black on paper, white in the dark).
struct WWRecordButton: View {
    var diameter: CGFloat = 62
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(WW.ember)
                // `strokeBorder`, not `stroke`: the ring is drawn inside the circle, so the button
                // stays exactly `diameter` across instead of growing by the line width.
                .overlay(Circle().strokeBorder(WW.recordRing, lineWidth: 3))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(DotStyle())
        .accessibilityLabel("New Recording")
    }

    /// Press feedback only — the dot itself is the whole button.
    private struct DotStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.55 : 1)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

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
