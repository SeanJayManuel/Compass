import AppKit
import Core
import SwiftUI

/// Compass's design tokens. Every screen takes color, type, spacing and
/// motion from here, so nothing needs restyling later.
enum Palette {
    /// The canvas, ink and rules (`ColorTheme`, Workbench): near-neutral
    /// greys, white cards on light grey, and near-black in dark mode.
    static var canvas: Color { themeColors.canvas }
    static var ink: Color { themeColors.ink }
    static var inkSecondary: Color { themeColors.inkSecondary }
    static var rule: Color { themeColors.rule }
    /// The sidebar's fill, for themes that set one; nil keeps the system's.
    static var sidebar: Color? { themeColors.sidebar }
    /// The sidebar's selected row: a quiet ink tint, so the accent stays on
    /// the row's icon alone. Hover is fainter still.
    static var selection: Color { ink.opacity(0.08) }
    static var hover: Color { ink.opacity(0.045) }
    /// The one accent: the chart line, the selected range and the sidebar's
    /// selected row. Never decoration. Follows the preset or custom color
    /// chosen in Settings. A fill or a graphic: in dark mode it sits near 17%
    /// luminance (3:1 or more on the canvas and cards, 4.5:1 under white), too
    /// deep for small text there. Text on it takes `onNeedle`; the accent as
    /// text takes `needleText`. It stays the window's tint because macOS draws
    /// default, confirmation and prominent buttons and checkboxes in the tint
    /// with a fixed white label.
    static var needle: Color { accentColors.fill }

    /// Text and symbols on a `needle` fill: white or near-black, whichever
    /// contrasts more with the accent in each mode, custom colors included.
    /// Every preset and custom color takes white today (4.5:1 or more); this
    /// keeps holding if one ever doesn't.
    static var onNeedle: Color { accentColors.label }

    /// The accent as text and links: the fill in light mode, a lighter value
    /// of the same hue in dark mode. 4.5:1 or more on the canvas, the cards
    /// and alternating rows in both modes. Borderless buttons and menus draw
    /// their label in the tint, so a text control takes `.tint(needleText)`.
    static var needleText: Color { accentColors.text }

    /// Whether links need an underline: the accent as text is within 2:1 of
    /// the ink in light mode (the Graphite accent), so color alone
    /// can't mark them.
    static var linksNeedUnderline: Bool {
        _ = AccentState.shared.signature
        return ColorMath.contrast(AccentTheme.current.light, ColorTheme.current.values.ink.light) < 2
    }

    /// Reading `AccentState` here makes every view that draws with the accent
    /// redraw when it changes, without being rebuilt, so its state survives.
    /// The cache is keyed on the preset and the custom color.
    private static var accentColors: AccentColors {
        _ = AccentState.shared.signature
        let signature = AccentTheme.signature
        if let cached = accentCache, cached.signature == signature { return cached.colors }
        let theme = AccentTheme.current
        let colors = AccentColors(
            fill: dynamic(light: theme.light, dark: theme.dark),
            label: label(light: theme.light, dark: theme.dark),
            text: dynamic(light: theme.light, dark: theme.darkText))
        accentCache = (signature, colors)
        return colors
    }

    private struct AccentColors {
        let fill: Color
        let label: Color
        let text: Color
    }

    nonisolated(unsafe) private static var accentCache: (signature: String, colors: AccentColors)?

    /// A preset's own color, for its swatch in Settings.
    static func accent(_ theme: AccentTheme) -> Color { dynamic(light: theme.light, dark: theme.dark) }

    /// Any light and dark pair, for previews.
    static func pair(light: UInt32, dark: UInt32) -> Color { dynamic(light: light, dark: dark) }

    /// The label for text on a fill of this light and dark pair.
    static func label(light: UInt32, dark: UInt32) -> Color {
        dynamic(light: ColorMath.label(on: light), dark: ColorMath.label(on: dark))
    }

    /// The label for text on one fixed color.
    static func label(on fill: UInt32) -> Color { Color(nsColor: NSColor(hex: ColorMath.label(on: fill))) }

    // Status only.
    static let onPace = status(.onPace)
    static let behind = status(.behind)
    static let stale = dynamic(light: 0x8A857C, dark: 0x8A857C)
    static let failure = status(.failure)
    /// Needs a look but isn't wrong: uncategorized money, things to tidy up.
    /// The same amber as `behind`, so amber keeps one meaning.
    static let attention = behind

    private static func status(_ hue: StatusHue) -> Color { dynamic(light: hue.light, dark: hue.dark) }

    /// Cards sit on the canvas: white, and a raised near-black in dark mode.
    static var surface: Color { themeColors.surface }

    /// Read like `accentColors`, so a new theme redraws what's drawn with it.
    private static var themeColors: ThemeColors {
        _ = AccentState.shared.signature
        let theme = ColorTheme.current
        if let cached = themeCache, cached.theme == theme { return cached.colors }
        let values = theme.values
        func pair(_ pair: ColorTheme.Pair) -> Color { dynamic(light: pair.light, dark: pair.dark) }
        let colors = ThemeColors(
            canvas: pair(values.canvas), surface: pair(values.surface), ink: pair(values.ink),
            inkSecondary: pair(values.inkSecondary), rule: pair(values.rule),
            sidebar: values.sidebar.map(pair))
        themeCache = (theme, colors)
        return colors
    }

    private struct ThemeColors {
        let canvas, surface, ink, inkSecondary, rule: Color
        let sidebar: Color?
    }

    nonisolated(unsafe) private static var themeCache: (theme: ColorTheme, colors: ThemeColors)?
    /// The accent at 10%, for area fills under a line.
    static var needleWash: Color { needle.opacity(0.12) }
    /// A selected segment or pill: a quiet ink tint with the label in ink,
    /// as the draft's segmented controls (the accent stays for links and the
    /// sidebar's current screen).
    static var selectedFill: Color { ink.opacity(0.1) }
    /// How far along something is (a budget spent, a goal, a quarter):
    /// ink, not the accent, so a gray accent never makes progress look
    /// switched off. A meter turns amber or red only
    /// when there's a problem; green when a goal is reached.
    static var progress: Color { ink.opacity(0.78) }
    static var progressTrack: Color { ink.opacity(0.1) }

    /// One color per account class, fixed whatever the accent theme: the
    /// draft's softer blue, peach, mint, lilac and pink,
    /// re-ordered and re-stepped until the dataviz checks pass in on-screen
    /// order (debt, cash, taxable, retirement, equity, other) on cards and
    /// canvas in both modes: lightness band, chroma, adjacent colorblind and
    /// normal-vision separation, and 3:1 contrast. Charts still carry a legend.
    static func accountClass(_ accountClass: AccountClass) -> Color {
        switch accountClass {
        // Olive, not red: red means failed or over, and owing isn't either.
        case .debt: dynamic(light: 0x7C8A1A, dark: 0x8C9640)
        case .cash: dynamic(light: 0x2F6FE0, dark: 0x5B8FE8)
        case .taxable: dynamic(light: 0xC8641C, dark: 0xC97C40)
        case .retirement: dynamic(light: 0x108A72, dark: 0x33A189)
        case .equity: dynamic(light: 0x8A4FD8, dark: 0x9C72DC)
        case .otherAssets: dynamic(light: 0xC4407C, dark: 0xE0558A)
        }
    }

    /// Spending categories in charts, in fixed order: the five biggest get
    /// these (a validated adjacent order from the dataviz palette, without
    /// the status hues); everything else is neutral Other.
    static func series(_ index: Int) -> Color {
        let steps: [(UInt32, UInt32)] = [
            (0x2F6FE0, 0x5B8FE8), (0xC8641C, 0xC97C40), (0x108A72, 0x33A189),
            (0x8A4FD8, 0x9C72DC), (0xC4407C, 0xE0558A)
        ]
        guard steps.indices.contains(index) else { return otherSeries }
        return dynamic(light: steps[index].0, dark: steps[index].1)
    }

    static let otherSeries = dynamic(light: 0xB4B0A7, dark: 0x5E5A54)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
    }
}

/// The accent in use, observed. `Palette.needle` reads it, so a new accent
/// or custom color redraws exactly the views drawn with it. Fed by any
/// defaults change (Settings' @AppStorage writes post one); it only changes
/// when the accent does.
@Observable
final class AccentState {
    static let shared = AccentState()

    private(set) var signature = AccentTheme.signature
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AccentState.shared.refresh() }
        }
    }

    func refresh() {
        let current = AccentTheme.signature
        if current != signature { signature = current }
    }
}

extension View {
    /// The raised card every section sits on: 12 pt corners and a hairline
    /// edge, Workbench's card.
    func card(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: .rect(cornerRadius: Radius.card))
            .overlay(Hairline(cornerRadius: Radius.card))
    }
}

/// Corner radii, after Vult's: controls 8, cards and panels 12.
enum Radius {
    static let control: CGFloat = 8
    static let card: CGFloat = 12
}

/// A card's edge: one physical pixel, as `Rule` is (half a point vanishes
/// or doubles at 1x), firmer and darker with Increase Contrast on.
struct Hairline: View {
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let increased = contrast == .increased
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(increased ? Palette.inkSecondary : Palette.rule, lineWidth: increased ? 1 : 1 / displayScale)
    }
}

/// How big text is drawn, chosen in Settings. Every type size scales with it.
enum TextSize: String, CaseIterable, Identifiable {
    case small, standard, large, larger

    static let key = "textSize"

    var id: String { rawValue }

    static var current: TextSize {
        UserDefaults.standard.string(forKey: key).flatMap(TextSize.init(rawValue:)) ?? .standard
    }

    var name: String {
        switch self {
        case .small: "Small"
        case .standard: "Standard"
        case .large: "Large"
        case .larger: "Larger"
        }
    }

    /// The native control size that sits well beside this text size.
    var controlSize: ControlSize {
        switch self {
        case .small: .small
        case .standard: .regular
        case .large, .larger: .large
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1
        case .large: 1.12
        case .larger: 1.25
        }
    }
}

/// The face for titles, the hero and card figures, chosen in Settings apart
/// from the color theme. All have lining figures, so `.monospacedDigit()`
/// columns line up. Spectral and Geist Serif (Vercel's
/// display serif, Regular only) are bundled in App/Fonts under the OFL; the
/// rest ship with macOS.
enum DisplayFace: String, CaseIterable, Identifiable {
    case geist, newYork, spectral, geistSerif, charter, iowan, palatino, sfPro

    static let key = "typeface.display"

    var id: String { rawValue }

    static var current: DisplayFace {
        UserDefaults.standard.string(forKey: key).flatMap(DisplayFace.init(rawValue:)) ?? .geist
    }

    var name: String {
        switch self {
        case .geist: "Geist"
        case .newYork: "New York"
        case .spectral: "Spectral"
        case .geistSerif: "Geist Serif"
        case .charter: "Charter"
        case .iowan: "Iowan Old Style"
        case .palatino: "Palatino"
        case .sfPro: "SF Pro"
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .newYork: .system(size: size, weight: .regular, design: .serif)
        case .sfPro: .system(size: size, weight: .regular)
        default: .custom(name, fixedSize: size)
        }
    }
}

/// The face for everything else: body, labels, the sidebar and charts.
/// Geist (the default, Vercel's, after Vult) and Public Sans
/// are bundled like Spectral.
enum TextFace: String, CaseIterable, Identifiable {
    case geist, sfPro, publicSans, avenirNext, seravek, helveticaNeue

    static let key = "typeface.text"

    var id: String { rawValue }

    static var current: TextFace {
        UserDefaults.standard.string(forKey: key).flatMap(TextFace.init(rawValue:)) ?? .geist
    }

    var name: String {
        switch self {
        case .geist: "Geist"
        case .sfPro: "SF Pro"
        case .publicSans: "Public Sans"
        case .avenirNext: "Avenir Next"
        case .seravek: "Seravek"
        case .helveticaNeue: "Helvetica Neue"
        }
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        self == .sfPro ? .system(size: size, weight: weight) : .custom(name, fixedSize: size).weight(weight)
    }
}

/// Type sizes, scaled by the Settings text size, in the faces chosen in
/// Settings. The root view rebuilds when either changes, so these are read
/// fresh.
enum Typeface {
    private static var scale: CGFloat { TextSize.current.scale }
    private static func display(_ size: CGFloat) -> Font { DisplayFace.current.font(size: size * scale) }
    private static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        TextFace.current.font(size: size * scale, weight: weight)
    }

    /// The display face (Geist by default), for the one big figure per screen.
    static var hero: Font { display(64) }
    /// For screen titles: big enough to sit beside the hero figure.
    static var title: Font { display(40) }
    /// A card's or section's title: the draft's size, one step over body,
    /// so every screen's cards read alike.
    static var section: Font { text(15, .semibold) }
    /// For a card's own figure (smaller than the hero).
    static var figure: Font { display(30) }
    /// For a heading inside a screen: a resolution's title, the goal detail's
    /// figure. Smaller than `figure`, larger than `section`.
    static var heading: Font { display(22) }
    static var body: Font { text(15) }
    static var detail: Font { text(13) }
    /// Small print: footnotes, legends, badges.
    static var caption: Font { text(11) }
    /// Chart axis labels: `AxisValueLabel().font(Typeface.axis)`.
    static var axis: Font { text(11) }
    /// Sidebar rows and section labels, sized to sit with the 40 pt titles
    /// in full screen.
    static var sidebar: Font { text(15) }
    static var sidebarSection: Font { text(16, .semibold) }
}

/// The 8 pt grid.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    /// The content width every screen shares, centred in the window.
    static var column: CGFloat { 960 * TextSize.current.scale }
    /// A screen's content narrower than this puts its rows in `RowDensity.compact`.
    static var compactBelow: CGFloat { 640 * TextSize.current.scale }
}

extension View {
    /// A screen's content: one column, centred in the window however wide it
    /// gets (full screen included). A screen whose header stays put while its
    /// list scrolls pads the header's top and the list's bottom.
    ///
    /// It also measures the column once and publishes it as `\.rowDensity`, so
    /// rows can stack when the window is narrow without measuring themselves.
    func screenColumn(_ edges: Edge.Set = .vertical) -> some View { modifier(ScreenColumn(edges: edges)) }
}

private struct ScreenColumn: ViewModifier {
    let edges: Edge.Set
    @State private var density = RowDensity.regular

    func body(content: Content) -> some View {
        content
            .environment(\.rowDensity, density)
            .frame(maxWidth: Spacing.column, alignment: .leading)
            // Only the width crosses into the measuring closure; the threshold
            // reads the text size (main actor), so it's applied in `action`.
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                density = RowDensity(width: $0)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(edges, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Motion only answers a data change or navigation.
enum Motion {
    /// A critically damped spring. With Reduce Motion on, a short ease with
    /// no spring, so an opening section settles almost at once.
    static var change: Animation {
        reduced ? .easeInOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0)
    }

    /// A chart and its figures coming in after a switch of view or month:
    /// a fixed 0.4 s ease, so everything that moves stops together. Every
    /// frame of any animation costs the screen about 10 ms of main-thread
    /// work (measured on Spending, Nov 10, 2026), so the cost is how long
    /// things move, not what moves.
    static var switchIn: Animation {
        reduced ? .easeInOut(duration: 0.15) : .linear(duration: 0.4)
    }

    /// The Mac's Reduce Motion setting.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// An open-or-closed state that's remembered between launches and animates.
/// `@AppStorage` remembers, but its change lands outside `withAnimation`, so
/// a section kept that way popped open while state-backed ones slid.
@propertyWrapper
struct Remembered: DynamicProperty {
    @State private var value: Bool
    private let key: String

    init(wrappedValue: Bool, _ key: String) {
        self.key = key
        _value = State(initialValue: UserDefaults.standard.object(forKey: key) as? Bool ?? wrappedValue)
    }

    var wrappedValue: Bool {
        get { value }
        nonmutating set {
            value = newValue
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    var projectedValue: Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
