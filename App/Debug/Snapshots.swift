#if DEBUG
    import AppKit
    import SwiftData
    import SwiftUI

    /// Renders every screen offscreen to PNGs, for reviewing layout without
    /// driving the window (it works with the screen locked). Sandbox only:
    ///
    ///     Compass Dev --sandbox --seed-demo --snapshots <folder> [--snapshot-size 1440x1800]
    ///         [--snapshot-screens money,spending] [--appearance dark]
    ///         [--snapshot-defaults textSize=larger,accounts.expanded.cash=true] [--snapshot-suffix larger]
    ///
    /// `--snapshot-defaults` sets preferences for this run only: they go in the
    /// launch-argument domain, which is never saved, so nothing is left behind
    /// even if the run is cut short. "true"/"false" become booleans and numbers
    /// become numbers; anything else is a string.
    ///
    /// Files are named after the appearance actually drawn: `--appearance` if
    /// given, else the Appearance setting, else the system's. Settings is drawn
    /// one tab per image (`settings-appearance-dark.png`) in the same frame
    /// and at the same size as the other screens, with its native selector.
    ///
    /// Numbers wait for a net worth computed from the store as it is after the
    /// demo seed. Each screen is drawn in a tall offscreen window so scrolled
    /// content is included, then the app quits.
    enum SnapshotRunner {
        static func startIfRequested(container: ModelContainer, storeURL: URL, keychainAccount: String) {
            let arguments = CommandLine.arguments
            guard DataEnvironment.current == .sandbox,
                let flag = arguments.firstIndex(of: "--snapshots"), arguments.indices.contains(flag + 1)
            else { return }
            let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var size = CGSize(width: 1440, height: 1800)
            if let sizeFlag = arguments.firstIndex(of: "--snapshot-size"), arguments.indices.contains(sizeFlag + 1) {
                let parts = arguments[sizeFlag + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
            }
            var screens = Navigator.order
            var menuBar = true
            var lockScreen = true
            if let screensFlag = arguments.firstIndex(of: "--snapshot-screens"), arguments.indices.contains(screensFlag + 1) {
                let names = Set(arguments[screensFlag + 1].split(separator: ",").map(String.init))
                screens = screens.filter { names.contains(name(of: $0)) }
                menuBar = names.contains("menubar")
                lockScreen = names.contains("lock")
            }
            applyDefaults(value(after: "--snapshot-defaults") ?? "")
            let sync = SyncService(context: container.mainContext, keychain: Keychain(account: keychainAccount))
            // A cache of its own, on a scratch file, so it can't start from the
            // store's cache file: the demo seed has just saved, and a file dated
            // today would never be recomputed. It starts empty and fills from the
            // store as it is now.
            let scratch = URL.temporaryDirectory.appending(path: "CompassSnapshots-\(UUID().uuidString).store")
            let cache = NetWorthCache(container: container, storeURL: scratch)
            let pay = PayCache(container: container)
            let search = SearchCache(container: container)
            let lock = AppLock()
            let reminders = RemindersService(demo: true)
            let calendar = CalendarService(demo: true)
            let ticker = HabitTicker(reminders: reminders)
            let claude = ClaudeEndpoint(tools: ClaudeTools(container: container, netWorth: cache, reminders: reminders, calendar: calendar))
            let suffix = value(after: "--snapshot-suffix").map { "-\($0)" } ?? ""

            // exit() skips defer, so each way out removes the scratch file itself.
            func finish(_ message: String, status: Int32) -> Never {
                try? FileManager.default.removeItem(at: scratch.deletingPathExtension().appendingPathExtension("cache.json"))
                FileHandle.standardError.write(Data("[snapshots] \(message)\n".utf8))
                exit(status)
            }

            Task { @MainActor in
                guard await waitForNumbers(cache, container: container) else {
                    finish("net worth didn't compute within 60 s; no images written", status: 1)
                }
                // The flexible budget plans with the paychecks, read off the main thread.
                while pay.paychecks == nil { try? await Task.sleep(for: .milliseconds(50)) }
                let scheme = colorScheme()
                let appearanceName = scheme == .dark ? "dark" : "light"
                for screen in screens {
                    let navigator = Navigator()
                    navigator.screen = screen
                    let view = MainView()
                        .environment(lock)
                        .environment(sync)
                        .environment(cache)
                        .environment(pay)
                        .environment(search)
                        .environment(navigator)
                        .environment(reminders)
                        .environment(calendar)
                        .environment(claude)
                        .environment(ticker)
                        .environment(MenuBarSetting())
                        .modelContainer(container)
                        .tint(Palette.needle)
                        .accentColor(Palette.needle)
                        .preferredColorScheme(scheme)
                        .frame(width: size.width, height: size.height)
                    await render(
                        view, size: size, scheme: scheme,
                        to: folder.appending(path: "\(name(of: screen))-\(appearanceName)\(suffix).png"))
                }
                // The menu bar panel's content, without its lock gate (this run's AppLock is locked).
                if menuBar {
                    let panelSize = CGSize(width: 380 * TextSize.current.scale, height: 1500)
                    let panel = TodayView()
                        .environment(pay)
                        .environment(Navigator())
                        .environment(reminders)
                        .environment(ticker)
                        .modelContainer(container)
                        .tint(Palette.needle)
                        .accentColor(Palette.needle)
                        .preferredColorScheme(scheme)
                        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
                        .background(Palette.canvas)
                    await render(
                        panel, size: panelSize, scheme: scheme,
                        to: folder.appending(path: "menubar-\(appearanceName)\(suffix).png"))
                }
                if lockScreen {
                    let locked = LockView().environment(lock)
                        .tint(Palette.needle).preferredColorScheme(scheme)
                        .frame(width: size.width, height: size.height)
                    await render(
                        locked, size: size, scheme: scheme,
                        to: folder.appending(path: "lock-\(appearanceName)\(suffix).png"))
                }
                // Settings tabs in the actual frame, at the requested matrix size.
                let settingsSize = size
                for tab in SettingsTab.allCases {
                    let navigator = Navigator()
                    navigator.screen = .settings
                    let page = AppFrame { SettingsView(fixedTab: tab) }
                        .environment(navigator)
                        .environment(search)
                        .environment(lock)
                        .environment(sync)
                        .environment(reminders)
                        .environment(calendar)
                        .environment(claude)
                        .environment(MenuBarSetting())
                        .modelContainer(container)
                        .id(TextSize.current)
                        .tint(Palette.needle)
                        .accentColor(Palette.needle)
                        .preferredColorScheme(scheme)
                        .frame(width: settingsSize.width, height: settingsSize.height)
                    await render(
                        page, size: settingsSize, scheme: scheme,
                        to: folder.appending(path: "settings-\(tab.rawValue)-\(appearanceName)\(suffix).png"))
                }
                finish("wrote \(screens.count + SettingsTab.allCases.count + (menuBar ? 1 : 0) + (lockScreen ? 1 : 0)) images to \(folder.path)", status: 0)
            }
        }

        /// Waits until the cache has computed from the store. With no balances
        /// there's nothing to wait for. False if it takes more than a minute.
        @MainActor
        private static func waitForNumbers(_ cache: NetWorthCache, container: ModelContainer) async -> Bool {
            let balances = (try? container.mainContext.fetchCount(FetchDescriptor<SnapshotRecord>())) ?? 0
            guard balances > 0 else { return true }
            for _ in 0..<600 {
                if !cache.breakdown.isEmpty && !cache.latest.isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }

        /// The appearance to draw: `--appearance`, else the Appearance setting,
        /// else the system's.
        @MainActor
        private static func colorScheme() -> ColorScheme {
            switch value(after: "--appearance") {
            case "dark": return .dark
            case "light": return .light
            default:
                let setting = UserDefaults.standard.string(forKey: Appearance.key).flatMap(Appearance.init(rawValue:)) ?? .system
                if let scheme = setting.colorScheme { return scheme }
                return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            }
        }

        /// Puts `key=value` pairs in the launch-argument domain, which outranks
        /// saved preferences and is never written to disk.
        private static func applyDefaults(_ list: String) {
            let defaults = UserDefaults.standard
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            for pair in list.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let text = parts[1]
                let value: Any =
                    if let number = Int(text) { number } else if let number = Double(text) { number } else if text == "true" || text == "false" {
                        text == "true"
                    } else { text }
                arguments[parts[0]] = value
            }
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }

        private static func value(after flag: String) -> String? {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        private static func name(of screen: Screen) -> String {
            "\(screen)"
        }

        @MainActor
        private static func render(_ view: some View, size: CGSize, scheme: ColorScheme, to url: URL) async {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            // AppKit controls take their look from the window, not the SwiftUI preference.
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            // Tasks on the screen fetch and lay out; give them a moment.
            try? await Task.sleep(for: .seconds(2.5))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
            window.orderOut(nil)
        }
    }
#endif
