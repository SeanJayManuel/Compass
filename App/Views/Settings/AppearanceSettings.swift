import AppKit
import SwiftUI

/// Light or dark, the accent, the text size, the typefaces
/// and the app icon.
struct AppearanceSettings: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(AccentTheme.key) private var accent = AccentTheme.theme
    @AppStorage(DisplayFace.key) private var displayFace = DisplayFace.geist
    @AppStorage(TextFace.key) private var textFace = TextFace.geist
    @AppStorage(AccentTheme.customKey) private var customHex = ""
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @AppStorage(AppMark.key) private var mark = AppMark.current
    @AppStorage(IconColor.key) private var iconColor = IconColor.accent
    @Environment(MenuBarSetting.self) private var menuBar
    /// The picker's color while it moves; stored a moment after it settles,
    /// so dragging doesn't redraw every screen on every step.
    @State private var draft = Color(nsColor: NSColor(hex: CustomAccent.current.picked))
    @State private var commit: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Match the Mac").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented)
                Picker("Text size", selection: $textSize) {
                    ForEach(TextSize.allCases) { size in
                        Text(size.name).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                SettingsNote("Text size sets the type on every screen and chart, the sidebar and these settings.")
            } header: {
                SettingsHeader("Appearance")
            }

            Section {
                Toggle("Show Compass in the menu bar", isOn: Bindable(menuBar).shown)
                SettingsNote(
                    "Today's reminders, your habits and what's left to spend this month, from the menu bar. While it's on, closing the window keeps Compass running, locked until you open it again."
                )
            } header: {
                SettingsHeader("Menu bar")
            }

            Section {
                swatches
                if accent == .custom {
                    customColor
                }
                SettingsNote("Colors the chart line, selections, the selected sidebar row and, when it matches the accent, the app icon.")
            } header: {
                SettingsHeader("Accent")
            }

            Section {
                Picker("Headings", selection: $displayFace) {
                    ForEach(DisplayFace.allCases) { face in
                        Text(face.name).font(face.font(size: 13)).tag(face)
                    }
                }
                Picker("Text", selection: $textFace) {
                    ForEach(TextFace.allCases) { face in
                        Text(face.name).font(face.font(size: 13)).tag(face)
                    }
                }
                SettingsNote("Headings sets the titles and the big figures; Text sets everything else.")
            } header: {
                SettingsHeader("Typeface")
            }

            Section {
                icons
                iconColors
                SettingsNote(
                    "Shown in the Dock while Compass is open, in its own color or the accent's. Finder, and the Dock when Compass is closed, pick up a new choice the next time Compass is updated."
                )
            } header: {
                SettingsHeader("App icon")
            }
        }
        .settingsPane()
        .onChange(of: draft) { _, color in schedule(color) }
    }

    // MARK: Accent

    private var swatches: some View {
        let scale = TextSize.current.scale
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: 12 * scale) {
                swatch(for: .theme) {
                    // The theme's own accent, split with its canvas: "this theme's color".
                    let values = ColorTheme.current.values
                    Circle().fill(Palette.pair(light: values.canvas.light, dark: values.canvas.dark))
                        .overlay(Circle().trim(from: 0, to: 0.5).fill(Palette.accent(.theme)).rotationEffect(.degrees(-45)))
                        .overlay(Circle().strokeBorder(Palette.rule, lineWidth: 1))
                }
                ForEach(AccentTheme.presets) { theme in
                    swatch(for: theme) { Circle().fill(Palette.accent(theme)) }
                }
                swatch(for: .custom) {
                    // A wheel of the colorful presets, in hue order: "any
                    // color", without the status hues.
                    Circle().fill(AngularGradient(colors: Self.wheel.map(Palette.accent), center: .center))
                        .overlay {
                            Image(systemName: "eyedropper")
                                .font(.system(size: 11 * scale, weight: .semibold))
                                .foregroundStyle(Palette.label(light: AccentTheme.cobalt.light, dark: AccentTheme.cobalt.dark))
                        }
                }
            }
            Text(accent == .custom ? "Custom" : accent.name)
                .font(Typeface.detail)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, Spacing.xs)
    }

    private static let wheel: [AccentTheme] = [.lagoon, .harbor, .cobalt, .iris, .orchid, .berry, .lagoon]

    private func swatch(for theme: AccentTheme, @ViewBuilder fill: () -> some View) -> some View {
        let scale = TextSize.current.scale
        let selected = theme == accent
        return Button {
            choose(theme)
        } label: {
            fill()
                .frame(width: 26 * scale, height: 26 * scale)
                .padding(3 * scale)
                .overlay(Circle().strokeBorder(Palette.ink, lineWidth: selected ? 2 : 0))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(theme == .custom ? "Custom" : theme.name)
        .accessibilityLabel(theme == .custom ? "Custom accent" : theme == .theme ? "The theme's own accent" : "\(theme.name) accent")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ theme: AccentTheme) {
        if theme == .custom, accent != .custom {
            if let saved = ColorMath.hex(customHex) {
                // Back to the color picked before.
                draft = Color(nsColor: NSColor(hex: saved))
            } else {
                // The first time, start from the accent in use, so switching
                // changes nothing until the color does.
                let start = AccentTheme.current.light
                customHex = ColorMath.hexString(start)
                draft = Color(nsColor: NSColor(hex: start))
            }
        }
        accent = theme
    }

    private var customColor: some View {
        let picked = ColorMath.hex(NSColor(draft)) ?? CustomAccent.fallback
        let custom = CustomAccent(picked: picked)
        let scale = TextSize.current.scale
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                ColorPicker("Custom color", selection: $draft, supportsOpacity: false)
                Spacer()
                ForEach([("Light", custom.light), ("Dark", custom.dark)], id: \.0) { label, value in
                    HStack(spacing: Spacing.xs) {
                        RoundedRectangle(cornerRadius: 5 * scale)
                            .fill(Color(nsColor: NSColor(hex: value)))
                            .frame(width: 34 * scale, height: 20 * scale)
                            .overlay {
                                Text("Aa").font(.system(size: 11 * scale, weight: .semibold)).foregroundStyle(Palette.label(on: value))
                            }
                        Text(label).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
            if let status = custom.nearStatus {
                SettingsNote("This is close to \(status.meaning), so the two can blur together. A blue, purple or pink keeps them apart.")
            }
            if custom.deepened {
                SettingsNote("Deepened a little in light mode so white text reads on it.")
            }
        }
    }

    private func schedule(_ color: Color) {
        guard let picked = ColorMath.hex(NSColor(color)) else { return }
        let hex = ColorMath.hexString(picked)
        commit?.cancel()
        guard hex != customHex else { return }
        commit = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            customHex = hex
        }
    }

    // MARK: Icon

    /// The icon's own color: the accent's, or a fixed one.
    private var iconColors: some View {
        let scale = TextSize.current.scale
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: 12 * scale) {
                ForEach(IconColor.allCases) { option in
                    let selected = option == iconColor
                    Button {
                        iconColor = option
                    } label: {
                        Group {
                            if option == .accent {
                                // Split like the theme swatch: "whatever the accent is".
                                Circle().fill(Palette.canvas)
                                    .overlay(Circle().trim(from: 0, to: 0.5).fill(Palette.needle).rotationEffect(.degrees(-45)))
                                    .overlay(Circle().strokeBorder(Palette.rule, lineWidth: 1))
                            } else {
                                Circle().fill(Color(nsColor: NSColor(hex: option.fill)))
                            }
                        }
                        .frame(width: 26 * scale, height: 26 * scale)
                        .padding(3 * scale)
                        .overlay(Circle().strokeBorder(Palette.ink, lineWidth: selected ? 2 : 0))
                        .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(option.name)
                    .accessibilityLabel("Icon color: \(option.name)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(iconColor.name)
                .font(Typeface.detail)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, Spacing.xs)
    }

    private var icons: some View {
        let scale = TextSize.current.scale
        // The custom color as it moves, not as last stored, so the previews
        // keep up with the Light and Dark chips.
        let light =
            iconColor != .accent
            ? iconColor.fill
            : accent == .custom
                ? CustomAccent(picked: ColorMath.hex(NSColor(draft)) ?? CustomAccent.fallback).light
                : accent.light
        let tint = NSColor(hex: light)
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 80 * scale), spacing: Spacing.m, alignment: .top)],
            alignment: .leading, spacing: Spacing.m
        ) {
            ForEach(AppMark.allCases, id: \.rawValue) { option in
                let selected = option == mark
                Button {
                    mark = option
                } label: {
                    VStack(spacing: Spacing.xs) {
                        Image(nsImage: IconArt.image(accent: tint, mark: option, size: 56 * scale))
                            .resizable()
                            .frame(width: 56 * scale, height: 56 * scale)
                            .padding(4 * scale)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16 * scale)
                                    .strokeBorder(selected ? Palette.ink : .clear, lineWidth: 2))
                        Text(option.name)
                            .font(Typeface.detail)
                            .foregroundStyle(selected ? Palette.ink : Palette.inkSecondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.name) icon")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
