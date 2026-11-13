import AppKit
import SwiftUI

// Self-contained apart from `NSColor(hex:)` in IconArt.swift:
// scripts/export-icon builds this file with only IconArt.swift.

/// The accent color, chosen in Settings: one of eight presets or a custom
/// color, in two roles. As a fill (`light`, `dark`) it takes white text
/// (4.5:1 or more) and stands out from the canvas and the cards (3:1 or
/// more) in both modes. As text it is the same in light mode, and in dark
/// mode a lighter value of the same hue (`darkText`) that reads on the dark
/// canvas, cards and alternating rows (4.5:1 or more). One dark value can't
/// do both: macOS draws default, confirmation and prominent buttons in the
/// tint with a fixed white label. Greens, ambers and reds are left out: they
/// mean on pace, behind and failure.
enum AccentTheme: String, CaseIterable, Identifiable {
    // The color theme's own accent first, then the presets in hue order, as
    // Settings shows them.
    case theme, lagoon, harbor, cobalt, iris, orchid, berry, slate, graphite, custom

    static let key = "accent"
    /// The custom color as picked, `#RRGGBB`.
    static let customKey = "accent.custom"

    var id: String { rawValue }

    /// Earlier presets map onto their nearest new one, so a saved choice
    /// carries over.
    init?(rawValue: String) {
        switch rawValue {
        case "cobalt": self = .cobalt
        case "lagoon", "ocean": self = .lagoon
        case "harbor": self = .harbor
        case "iris", "plum": self = .iris
        case "orchid": self = .orchid
        case "berry", "rose": self = .berry
        case "slate": self = .slate
        case "graphite": self = .graphite
        case "custom": self = .custom
        case "theme": self = .theme
        default: return nil
        }
    }

    static var current: AccentTheme {
        UserDefaults.standard.string(forKey: key).flatMap(AccentTheme.init(rawValue:)) ?? .theme
    }

    static var presets: [AccentTheme] { allCases.filter { $0 != .custom && $0 != .theme } }

    /// Changes whenever the accent in use does, the custom color and the
    /// color theme included.
    static var signature: String {
        let theme = current
        let accent = theme == .custom ? "custom-\(CustomAccent.storedHex)" : theme.rawValue
        return "\(ColorTheme.current.rawValue)-\(accent)"
    }

    var name: String { self == .theme ? "Default" : rawValue.capitalized }

    var light: UInt32 { self == .custom ? CustomAccent.current.light : values.light }
    var dark: UInt32 { self == .custom ? CustomAccent.current.dark : values.dark }
    /// The accent as text in dark mode. In light mode the fill serves.
    var darkText: UInt32 { self == .custom ? CustomAccent.current.darkText : values.darkText }

    /// Tuned in OKLCH, one hue each, kept at least 38° from the status hues:
    /// light values sit near 10–12% luminance, dark ones near 17%, the band
    /// where white text and the dark canvas both read. The dark text values
    /// are the dark ones moved to about 33% luminance (`CustomAccent.textBand`)
    /// with the same hue and chroma, less where the gamut runs out.
    private var values: (light: UInt32, dark: UInt32, darkText: UInt32) {
        switch self {
        case .theme: ColorTheme.current.values.accent
        case .cobalt, .custom: (0x393FDB, 0x4F61FD, 0x7E96FF)  // hue 272
        case .lagoon: (0x006C75, 0x007F8A, 0x46AAB5)  // 205, a deep teal
        case .harbor: (0x0066A2, 0x0079BE, 0x43A3EC)  // 245, sea blue
        case .iris: (0x7738C9, 0x8C52E3, 0xB086FF)  // 298, violet
        case .orchid: (0x9E319E, 0xB346B2, 0xE272DF)  // 328, magenta
        case .berry: (0xB12477, 0xC73C8A, 0xF86AB4)  // 350, raspberry
        case .slate: (0x4C5F74, 0x62768A, 0x899EB4)  // 251, blue-gray
        case .graphite: (0x4D4A48, 0x757370, 0x9E9C99)  // warm neutral
        }
    }
}

/// The canvas, cards, ink and rules: one palette, Workbench, in light
/// and dark, near-neutral greys after Vult's, with a blue accent the Accent
/// setting can override. Status and series colors never change with it. It
/// keeps the contrast rules of `AccentTheme` and `StatusHue`: text 4.5:1 on
/// its canvas and cards in both modes, amber included; the accent fill 3:1
/// against them and 4.5:1 under white. Stored names of the old themes read
/// as Workbench.
enum ColorTheme: String, CaseIterable, Identifiable {
    case workbench

    static let key = "theme"

    var id: String { rawValue }

    static var current: ColorTheme { .workbench }

    var name: String { rawValue.capitalized }

    struct Pair {
        let light: UInt32
        let dark: UInt32
    }

    struct Values {
        let canvas: Pair
        let surface: Pair
        let ink: Pair
        let inkSecondary: Pair
        let rule: Pair
        /// The sidebar's own fill; nil keeps the system's.
        let sidebar: Pair?
        /// As in `AccentTheme`: the fill in each mode, and the text in dark mode.
        let accent: (light: UInt32, dark: UInt32, darkText: UInt32)
    }

    var values: Values {
        Values(
            canvas: Pair(light: 0xF4F4F5, dark: 0x0A0A0B), surface: Pair(light: 0xFFFFFF, dark: 0x151517),
            ink: Pair(light: 0x0B0B0D, dark: 0xF4F4F5), inkSecondary: Pair(light: 0x63636D, dark: 0x8F8F98),
            rule: Pair(light: 0xE4E4E7, dark: 0x2A2A2E), sidebar: Pair(light: 0xFAFAFA, dark: 0x111113),
            accent: (0x006EDB, 0x006EDB, 0x53ADFF))
    }
}

/// The app icon's color, chosen apart from the theme and the accent: the
/// accent in use, or one fixed color. The mark is drawn in paper, so each
/// fixed color is deep enough for it at 16 px.
enum IconColor: String, CaseIterable, Identifiable {
    case accent, midnight, ultramarine, navy, ink, graphite

    static let key = "icon.color"

    var id: String { rawValue }

    static var current: IconColor {
        UserDefaults.standard.string(forKey: key).flatMap(IconColor.init(rawValue:)) ?? .accent
    }

    var name: String { self == .accent ? "Match the accent" : rawValue.capitalized }

    var fill: UInt32 {
        switch self {
        case .accent: AccentTheme.current.light
        case .midnight: 0x0D1B33
        case .ultramarine: 0x13299A
        case .navy: 0x1F3459
        case .ink: 0x121418
        case .graphite: 0x3A3936
        }
    }
}

/// A color picked in Settings, made readable in each mode: same hue,
/// lightness moved just enough for white text, the canvas and, as text, the
/// cards and rows.
struct CustomAccent: Equatable {
    let picked: UInt32
    let light: UInt32
    let dark: UInt32
    let darkText: UInt32

    static let fallback: UInt32 = 0x393FDB

    init(picked: UInt32) {
        self.picked = picked
        light = ColorMath.clampLuminance(picked, to: Self.lightBand)
        dark = ColorMath.clampLuminance(picked, to: Self.darkBand)
        darkText = ColorMath.clampLuminance(picked, to: Self.textBand)
    }

    /// Luminance bands. Light: white text on it, and it as text on the light
    /// cards and alternating rows, need 0.16 or less. Dark fill: white text
    /// needs 0.183 or less; the dark canvas and cards need 0.156 or more.
    /// Dark text: the dark cards' alternating rows (about 0x32302D) need 0.31
    /// or more.
    static let lightBand: ClosedRange<Double> = 0...0.16
    static let darkBand: ClosedRange<Double> = 0.16...0.18
    static let textBand: ClosedRange<Double> = 0.33...0.37

    static var storedHex: String {
        UserDefaults.standard.string(forKey: AccentTheme.customKey) ?? ColorMath.hexString(fallback)
    }

    static var current: CustomAccent {
        let hex = storedHex
        if let cached = cache, cached.hex == hex { return cached.accent }
        let accent = CustomAccent(picked: ColorMath.hex(hex) ?? fallback)
        cache = (hex, accent)
        return accent
    }

    nonisolated(unsafe) private static var cache: (hex: String, accent: CustomAccent)?

    /// Whether the light value had to be deepened for white text.
    var deepened: Bool { light != picked }

    /// The status color this one is close enough to be mistaken for, if any:
    /// within 35° of its OKLCH hue. Grays never are.
    var nearStatus: StatusHue? {
        let mine = ColorMath.oklch(picked)
        guard mine.c >= 0.05 else { return nil }
        return StatusHue.allCases
            .map { ($0, ColorMath.hueDistance(mine.h, ColorMath.oklch($0.light).h)) }
            .filter { $0.1 < 35 }
            .min { $0.1 < $1.1 }?.0
    }
}

/// The status colors, kept apart from the accent. Palette.onPace, .behind and
/// .failure are built from these. As text they reach 4.5:1 on the canvas and
/// the cards in both modes; light amber, the lightest hue, is the tightest
/// (4.7:1 on the canvas, 5.1:1 on a card).
enum StatusHue: CaseIterable {
    case onPace, behind, failure

    var light: UInt32 {
        switch self {
        case .onPace: 0x2E7D4F
        case .behind: 0xA05E00
        case .failure: 0xB3261E
        }
    }

    var dark: UInt32 {
        switch self {
        case .onPace: 0x5CC48A
        case .behind: 0xE9A23B
        case .failure: 0xF2867E
        }
    }

    /// How Settings describes the clash.
    var meaning: String {
        switch self {
        case .onPace: "the green Compass uses for on pace"
        case .behind: "the amber Compass uses for behind"
        case .failure: "the red Compass uses for problems"
        }
    }
}

/// WCAG contrast and OKLCH (Björn Ottosson's OKLab in polar form) on
/// `0xRRGGBB` values. Display math only: no money passes through here.
enum ColorMath {
    static func hex(_ text: String) -> UInt32? {
        let digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

    static func hexString(_ value: UInt32) -> String {
        String(format: "#%06X", value & 0xFFFFFF)
    }

    /// The color as sRGB hex, if it converts.
    static func hex(_ color: NSColor) -> UInt32? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return packEncoded(Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    /// WCAG relative luminance.
    static func luminance(_ value: UInt32) -> Double {
        let (r, g, b) = linear(value)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// WCAG contrast ratio, 1 to 21.
    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The text color for a label on `fill`: white or near-black, whichever
    /// contrasts more. Fixed values, not the ink tokens, which flip with the
    /// mode.
    static func label(on fill: UInt32) -> UInt32 {
        contrast(white, fill) >= contrast(nearBlack, fill) ? white : nearBlack
    }

    static let white: UInt32 = 0xFFFFFF
    /// Warm near-black, the light-mode ink.
    static let nearBlack: UInt32 = 0x1C1B19

    /// Lightness 0–1, chroma, hue in degrees.
    static func oklch(_ value: UInt32) -> (l: Double, c: Double, h: Double) {
        let (r, g, b) = linear(value)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (lightness, (a * a + bb * bb).squareRoot(), hue)
    }

    /// The sRGB color at this lightness and hue, with chroma reduced until it
    /// fits the gamut.
    static func fromOKLCH(l: Double, c: Double, h: Double) -> UInt32 {
        if let exact = rgb(l: l, c: c, h: h) { return packLinear(exact) }
        var low = 0.0, high = c
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if rgb(l: l, c: mid, h: h) != nil { low = mid } else { high = mid }
        }
        return packLinear(rgb(l: l, c: low, h: h) ?? (l, l, l))
    }

    /// The same hue and chroma with lightness moved until luminance falls
    /// inside `band`. Already inside, it comes back unchanged.
    static func clampLuminance(_ value: UInt32, to band: ClosedRange<Double>) -> UInt32 {
        let current = luminance(value)
        guard !band.contains(current) else { return value }
        let target = current < band.lowerBound ? band.lowerBound + 0.004 : band.upperBound - 0.004
        let (_, c, h) = oklch(value)
        var low = 0.0, high = 1.0
        var best = value
        for _ in 0..<32 {
            let mid = (low + high) / 2
            let candidate = fromOKLCH(l: mid, c: c, h: h)
            best = candidate
            if luminance(candidate) < target { low = mid } else { high = mid }
        }
        return best
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    private static func linear(_ value: UInt32) -> (Double, Double, Double) {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return (channel(16), channel(8), channel(0))
    }

    /// Linear sRGB at an OKLCH point, nil when outside the gamut.
    private static func rgb(l: Double, c: Double, h: Double) -> (Double, Double, Double)? {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
        let g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
        let bl = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
        let range = -0.0001...1.0001
        guard range.contains(r), range.contains(g), range.contains(bl) else { return nil }
        return (r, g, bl)
    }

    private static func packLinear(_ linear: (Double, Double, Double)) -> UInt32 {
        func encode(_ c: Double) -> Double {
            let clamped = min(max(c, 0), 1)
            return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        return packEncoded(encode(linear.0), encode(linear.1), encode(linear.2))
    }

    private static func packEncoded(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        func byte(_ c: Double) -> UInt32 { UInt32((min(max(c, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
