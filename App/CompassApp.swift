import AppKit
import Core
import SwiftData
import SwiftUI

@main
struct CompassApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let environment = DataEnvironment.current
    private let container: ModelContainer
    @State private var lock = AppLock()
    @State private var sync: SyncService
    @State private var netWorth: NetWorthCache
    @State private var pay: PayCache
    @State private var search: SearchCache
    @State private var navigator: Navigator
    @State private var reminders: RemindersService
    @State private var calendar: CalendarService
    @State private var claude: ClaudeEndpoint
    @State private var ticker: HabitTicker
    @State private var menuBar = MenuBarSetting()
    private let playbookReminders: PlaybookReminders

    init() {
        let environment = DataEnvironment.current
        #if DEBUG
            DebugSupport.resetDemoIfRequested()
        #endif
        do {
            container = try CompassStore.container(for: environment)
        } catch let refused as CompassStore.Refused {
            let alert = NSAlert()
            alert.messageText = "This Compass is older than your data"
            alert.informativeText = refused.errorDescription ?? ""
            alert.runModal()
            exit(1)
        } catch {
            fatalError("Couldn't open the Compass store at \(environment.storeURL.path): \(error)")
        }
        _sync = State(
            initialValue: SyncService(
                context: container.mainContext,
                keychain: Keychain(account: environment.keychainAccount)
            ))
        if environment == .real { BackupWriter.startDaily(container: container, folder: environment.dailyBackupFolder) }
        let netWorth = NetWorthCache(container: container, storeURL: environment.storeURL)
        _netWorth = State(initialValue: netWorth)
        _pay = State(initialValue: PayCache(container: container))
        _search = State(initialValue: SearchCache(container: container))
        let navigator = Navigator()
        _navigator = State(initialValue: navigator)
        // Sample reminders in the sandbox, so no debug run asks for access.
        let reminders = RemindersService(demo: environment == .sandbox)
        let calendar = CalendarService(demo: environment == .sandbox)
        _reminders = State(initialValue: reminders)
        _calendar = State(initialValue: calendar)
        _ticker = State(initialValue: HabitTicker(reminders: reminders))
        playbookReminders = PlaybookReminders(container: container, reminders: reminders)
        _claude = State(
            initialValue: ClaudeEndpoint(
                tools: ClaudeTools(
                    container: container, netWorth: netWorth,
                    reminders: reminders, calendar: calendar)))
        #if DEBUG
            SelfCheck.runIfRequested()
            DebugSupport.prepare(container: container)
            PerfRunner.startIfRequested(navigator: navigator)
            SnapshotRunner.startIfRequested(
                container: container, storeURL: environment.storeURL,
                keychainAccount: environment.keychainAccount)
        #endif
    }

    var body: some Scene {
        Window(environment == .sandbox ? "Compass (Sandbox)" : "Compass", id: "main") {
            RootView()
                .environment(lock)
                .environment(sync)
                .environment(netWorth)
                .environment(pay)
                .environment(search)
                .environment(navigator)
                .environment(reminders)
                .environment(calendar)
                .environment(ticker)
                .environment(menuBar)
                .environment(claude)
                .frame(minWidth: 720, minHeight: 520)
        }
        // No title bar: the sidebar and top bar are the window's chrome.
        .windowStyle(.hiddenTitleBar)
        .modelContainer(container)
        // Opens filling the screen (menu bar and Dock aside), not at its minimum size.
        .defaultWindowPlacement { _, context in
            WindowPlacement(size: context.defaultDisplay.visibleRect.size)
        }
        // Always open the window at launch, even if it was closed before
        // quitting, unless Claude's bridge opened Compass in the background.
        .defaultLaunchBehavior(LaunchMode.inBackground ? .suppressed : .presented)
        .commands {
            SettingsCommands(navigator: navigator)
            RailCommands()
            SearchCommands(navigator: navigator)
            AmountsCommands()
            LockCommands(lock: lock)
            NetWorthViewCommands()
        }

        // Today, habits and what's left to spend, a click away. While it's on,
        // closing the window leaves Compass running (and locked).
        MenuBarExtra(isInserted: $menuBar.shown) {
            TodayPanel()
                .environment(lock)
                .environment(sync)
                .environment(pay)
                .environment(navigator)
                .environment(reminders)
                .environment(ticker)
                .modelContainer(container)
                .compassLook()
        } label: {
            Image(systemName: "location.north.circle")
                .accessibilityLabel("Compass")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window quits, as before, unless the menu bar panel is on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: MenuBarSetting.key) as? Bool ?? true)
    }
}

/// How this launch began.
enum LaunchMode {
    /// Opened by Claude's bridge (`open -g … --args --background`): no window until they open one.
    static let inBackground = CommandLine.arguments.contains("--background")
}
