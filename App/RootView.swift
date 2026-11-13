import AppKit
import Core
import SwiftData
import SwiftUI

/// While locked, the lock screen replaces every view, so no number exists to
/// show in Mission Control or a screen share.
struct RootView: View {
    @Environment(AppLock.self) private var lock
    @Environment(SyncService.self) private var sync
    @AppStorage(AccentTheme.key) private var accent = AccentTheme.theme
    @AppStorage(AccentTheme.customKey) private var customHex = ""
    @AppStorage(AppMark.key) private var mark = AppMark.current
    @AppStorage(IconColor.key) private var iconColor = IconColor.accent

    /// Changes with the preset, or the custom color while it's in use.
    private var accentSignature: String {
        switch accent {
        case .custom: "custom-\(customHex)"
        default: accent.rawValue
        }
    }

    var body: some View {
        Group {
            if lock.isLocked {
                LockView()
            } else {
                MainView()
            }
        }
        .compassLook()
        // Closing the window doesn't quit while the menu bar panel is on.
        .saveFailureAlert()
        .onDisappear { lock.windowClosed() }
        .onChange(of: "\(accentSignature)-\(mark.rawValue)-\(iconColor.rawValue)", initial: true) { _, _ in
            IconArt.applyToDock(accent: NSColor(hex: IconColor.current.fill))
            DockTileShare.save(mark: AppMark.current, accent: IconColor.current.fill)
        }
        // Only once they're using Compass: one opened in the background for
        // Claude asks for Touch ID when they bring it forward.
        .task { if NSApp.isActive { await lock.unlockIfNotDeclined() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await lock.unlockIfNotDeclined() }
        }
        // Never while locked: a sync's results would wait behind the lock anyway.
        .onChange(of: lock.isLocked) { _, locked in
            if !locked { Task { await sync.syncIfDue() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !lock.isLocked { Task { await sync.syncIfDue() } }
        }
    }
}

/// Appearance, text size and typefaces, accent: for the window and the menu bar panel.
private struct CompassLook: ViewModifier {
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(TextSize.key) private var textSize = TextSize.standard
    @AppStorage(DisplayFace.key) private var displayFace = DisplayFace.geist
    @AppStorage(TextFace.key) private var textFace = TextFace.geist

    func body(content: Content) -> some View {
        content
            // Rebuilt for a new text size or typeface, which every type token
            // reads. Not for the accent or color theme: the views drawn with them
            // redraw on their own (see AccentState), so searches, scroll and open
            // sheets survive.
            .id("\(textSize.rawValue)-\(displayFace.rawValue)-\(textFace.rawValue)")
            // The fill, not Palette.needleText: default, confirmation and
            // prominent buttons and checkboxes draw a fixed white label on the
            // tint. Text buttons take `.linkButton()`.
            .tint(Palette.needle)
            .accentColor(Palette.needle)
            .preferredColorScheme(appearance.colorScheme)
            // Native buttons, pickers and fields grow with the text size too.
            .controlSize(textSize.controlSize)
    }
}

extension View {
    func compassLook() -> some View { modifier(CompassLook()) }
}

struct MainView: View {
    var body: some View {
        AppFrame {
            ScreenView()
                .allowsHitTesting(Perf.takesPointer)
        }
    }
}

/// The screen the sidebar has chosen. On its own, so choosing another
/// screen redraws only this, not the sidebar or top bar.
private struct ScreenView: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        switch navigator.screen {
        case .money, nil: MoneyOverview().perfMark("screen.money")
        case .goals: GoalsView().perfMark("screen.goals")
        case .spending: SpendingView().perfMark("screen.spending")
        case .transactions: TransactionsView().perfMark("screen.transactions")
        case .life: LifeOverview()
        case .habits: HabitsView()
        case .playbook: PlaybookView()
        case .notes: NotesView()
        case .review: ReviewView().perfMark("screen.review")
        case .settings: SettingsView()
        }
    }
}
