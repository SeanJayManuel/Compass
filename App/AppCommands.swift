import AppKit
import Core
import SwiftData
import SwiftUI

struct AmountsCommands: Commands {
    @AppStorage(HideAmounts.key) private var hidden = false

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(hidden ? "Show Amounts" : "Hide Amounts") { hidden.toggle() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
        }
    }
}

struct LockCommands: Commands {
    let lock: AppLock

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Lock Now") { lock.lockNow() }
                .keyboardShortcut("l")
                .disabled(lock.mode == .off || lock.isLocked)
        }
    }
}

/// Settings shares the main window's lock gate and works even when only the menu bar is open.
struct SettingsCommands: Commands {
    let navigator: Navigator
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                navigator.isSearching = false
                navigator.screen = .settings
                openWindow(id: "main")
                NSApp.activate()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
