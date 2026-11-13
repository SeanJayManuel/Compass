import Core
import SwiftData
import SwiftUI

enum Appearance: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The Settings tabs. Remembered, so the sidebar's profile row can open
/// Profile and ⌘, comes back where it was left.
enum SettingsTab: String, CaseIterable {
    case profile, appearance, pay, security, data, guide

    static let key = "settings.tab"
}

extension SettingsTab {
    var title: String {
        switch self {
        case .profile: "Profile"
        case .appearance: "Appearance"
        case .pay: "Pay"
        case .security: "Security"
        case .data: "Data"
        case .guide: "How it works"
        }
    }
}

/// Each existing form lives in the canvas, under a native tab selector.
struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.profile
    /// Offscreen review can draw a tab without changing saved preferences.
    var fixedTab: SettingsTab? = nil

    private var selection: Binding<SettingsTab> { fixedTab.map { .constant($0) } ?? $tab }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ViewThatFits(in: .horizontal) {
                tabs.pickerStyle(.segmented).fixedSize()
                tabs.pickerStyle(.menu).fixedSize()
            }
            .font(Typeface.body)
            // Centred over the forms, which sit centred in the column
            // (so the top bar lines up with them).
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.xl)
            page(fixedTab ?? tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: Spacing.column)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.canvas)
        .environment(\.settingsInCanvas, true)
    }

    private var tabs: some View {
        Picker("Settings", selection: selection) {
            ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
    }

    @ViewBuilder private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .profile: ProfileSettings()
        case .appearance: AppearanceSettings()
        case .pay: PaySettings()
        case .security: SecuritySettings()
        case .data: DataSettings()
        case .guide: HowItWorksSettings()
        }
    }
}

extension EnvironmentValues {
    @Entry var settingsInCanvas = false
}

extension View {
    func settingsPane() -> some View { modifier(SettingsPane()) }
}

/// The same form typography in the canvas and in the changes-history sheet.
private struct SettingsPane: ViewModifier {
    @Environment(\.settingsInCanvas) private var inCanvas

    func body(content: Content) -> some View {
        let scale = TextSize.current.scale
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        content
            .formStyle(.grouped)
            .scrollContentBackground(inCanvas ? .hidden : .automatic)
            .background(inCanvas ? Palette.canvas : Color.clear)
            .font(Typeface.body)
            .controlSize(scale > 1.05 ? .large : .regular)
            .frame(
                minWidth: inCanvas ? nil : 680 * scale,
                minHeight: inCanvas ? nil : min(640 * scale, screen * 0.8))
    }
}

/// A Settings section's title, in the app's section type.
struct SettingsHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title).font(Typeface.section).foregroundStyle(Palette.ink)
    }
}

/// A line of explanation under a setting.
struct SettingsNote: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = Palette.inkSecondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(Typeface.detail)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum FileVault {
    /// Whether the volume holding Compass's data is encrypted.
    static var isOn: Bool {
        let values = try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeIsEncryptedKey])
        return values?.volumeIsEncrypted ?? true
    }
}
