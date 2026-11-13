import Core
import Darwin
import Foundation
import SwiftUI

/// Timing marks for the M6 performance run. Marks are free unless a run is
/// active; outside debug builds they do nothing at all.
enum Perf {
    #if DEBUG
        nonisolated(unsafe) static var runner: PerfRunner?
    #endif

    static func mark(_ name: String) {
        #if DEBUG
            runner?.reached(name)
        #endif
    }

    /// False during a performance run: wherever the pointer was left,
    /// hovering a chart mustn't start an animation in the middle of a timing.
    static var takesPointer: Bool {
        #if DEBUG
            runner == nil
        #else
            true
        #endif
    }
}

extension Notification.Name {
    /// The performance run types into the search panel (its object is the text).
    static let perfSearchText = Notification.Name("Compass.perfSearchText")
}

extension View {
    /// Reports when this screen appears, for the performance run.
    func perfMark(_ name: String) -> some View {
        onAppear { Perf.mark(name) }
    }
}

#if DEBUG
    /// `--sandbox --unlocked --seed-perf --perf-run`: on 10 years of synthetic
    /// data, times cold launch, opening each screen, and switching chart views
    /// and ranges, then idle memory; prints [perf] lines and quits.
    final class PerfRunner {
        private let navigator: Navigator
        private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        private var seen: Set<String> = []
        var activity: NSObjectProtocol?
        private let watch = MainThreadWatch()

        /// The window the screens are timed in: a 1440×900 display's full width.
        static let windowSize = CGSize(width: 1440, height: 780)

        init(navigator: Navigator) {
            self.navigator = navigator
        }

        static func startIfRequested(navigator: Navigator) {
            guard DataEnvironment.current == .sandbox, CommandLine.arguments.contains("--perf-run") else { return }
            let runner = PerfRunner(navigator: navigator)
            Perf.runner = runner
            // A hidden or occluded window gets throttled by App Nap, which would
            // measure the throttling instead of Compass.
            runner.activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Compass performance run"
            )
            runner.watch.start()
            Task { @MainActor in await runner.run() }
        }

        func reached(_ name: String) {
            seen.insert(name)
            waiting.removeValue(forKey: name)?.resume()
        }

        private func wait(for name: String) async {
            if seen.contains(name) { return }
            await withCheckedContinuation { waiting[name] = $0 }
        }

        /// Waits until the main thread has done everything a change set off
        /// (SwiftUI's update, layout, drawing, letting the last screen go) and
        /// returns when that work ended. A couple of main-queue turns isn't
        /// enough: layout and drawing can come in a later display cycle, and the
        /// last screen is let go after the new one is up.
        private func settle() async -> ContinuousClock.Instant {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [watch] in
                    continuation.resume(returning: watch.workEnd(idleFor: .milliseconds(25)))
                }
            }
        }

        /// Marks a screen posts when it shows a loading line.
        private static let loadingMarks = ["loading.spending", "loading.transactions"]

        /// Said after a timing when a loading line showed during it.
        private var loadingShown: String {
            Self.loadingMarks.contains(where: seen.contains) ? " — showed loading" : ""
        }

        private func report(_ line: String) {
            FileHandle.standardError.write(Data("[perf] \(line)\n".utf8))
        }

        private func ms(_ duration: Duration) -> String {
            String(format: "%.0f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
        }

        func run() async {
            await wait(for: "netWorth.chart")
            let launched = await settle()
            let launch = Date.now.timeIntervalSince(processStart) - (ContinuousClock.now - launched).inSeconds
            report("cold launch to net worth on screen: \(String(format: "%.0f ms", launch * 1000)) (budget 1000, Touch ID excluded)")
            // How much is on screen changes the timings, so every run after launch
            // uses the same window size (as much of it as the screen has room for),
            // whatever size the window was left at.
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView?.frame.width ?? 0 > 600 }),
                let screen = window.screen?.visibleFrame
            {
                let size = CGSize(width: min(Self.windowSize.width, screen.width), height: min(Self.windowSize.height, screen.height))
                window.setFrame(CGRect(x: screen.minX, y: screen.maxY - size.height, width: size.width, height: size.height), display: true)
                report("window: \(Int(window.frame.width))×\(Int(window.frame.height)) points")
            }

            let clock = ContinuousClock()
            try? await Task.sleep(for: .seconds(1))
            // Each screen is timed until its marks are reached and the main thread
            // has finished with it. The transactions list and Spending load off
            // the main thread, so they're timed until their rows are in, not just
            // until the screen appears.
            // Spending opens on whichever view was used last, so both are timed,
            // each chosen a moment before (a changed setting redraws the screen
            // on show), and the one in use is put back afterwards.
            let spendingView = UserDefaults.standard.string(forKey: SpendingChartView.key)
            let screens: [(screen: Screen, name: String, extraMarks: [String], spending: SpendingChartView?)] = [
                (.life, "life", [], nil), (.habits, "habits", [], nil), (.goals, "goals", [], nil), (.spending, "spending", ["spending.loaded"], .budget),
                (.transactions, "transactions", ["transactions.loaded"], nil),
                (.review, "review", [], nil), (.playbook, "playbook", [], nil), (.notes, "notes", [], nil),
                (.money, "money", [], nil), (.spending, "spending", ["spending.loaded"], .overTime),
                // Coming back: what the last visit read should show at once.
                (.money, "money", [], nil), (.spending, "spending", ["spending.loaded"], .budget),
                (.transactions, "transactions", ["transactions.loaded"], nil), (.money, "money", [], nil)
            ]
            var visited: Set<String> = []
            for (index, step) in screens.enumerated() {
                if let view = step.spending {
                    UserDefaults.standard.set(view.rawValue, forKey: SpendingChartView.key)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                let marks = ["screen.\(step.name)"] + step.extraMarks
                for mark in marks + Self.loadingMarks { seen.remove(mark) }
                let start = clock.now
                navigator.screen = step.screen
                for mark in marks { await wait(for: mark) }
                let end = await settle()
                var label = step.spending.map { "\(step.name) (\($0.title.lowercased()))" } ?? step.name
                if !visited.insert(label).inserted { label += " again" }
                // The last step only brings net worth back for the charts below.
                if index < screens.count - 1 {
                    report("open \(label): \(ms(end - start)) (budget 150)\(loadingShown)")
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            // Stepping Over time back a month: the bars grow and the figures roll.
            // Timed until idle, which includes the animation, and by how long the
            // main thread was actually busy in that time.
            UserDefaults.standard.set(SpendingChartView.overTime.rawValue, forKey: SpendingChartView.key)
            seen.remove("spending.loaded")
            navigator.screen = .spending
            await wait(for: "spending.loaded")
            _ = await settle()
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(400))
                seen.remove("spending.loaded")
                let start = clock.now
                let busy = watch.busy
                watch.resetStretches()
                for mark in Self.loadingMarks { seen.remove(mark) }
                navigator.spendingMonth = navigator.spendingMonth.adding(-1)
                await wait(for: "spending.loaded")
                let end = await settle()
                let stretches = watch.stretches
                report(
                    "spending over time, a month back: \(ms(end - start)), main thread busy \(ms(watch.busy - busy)) in \(stretches.wakes) wakes, longest \(ms(stretches.longest))\(loadingShown)"
                )
            }
            // Switching view on the screen and back.
            for view in [SpendingChartView.budget, .overTime] {
                try? await Task.sleep(for: .milliseconds(400))
                for mark in Self.loadingMarks + ["spending.loaded"] { seen.remove(mark) }
                let start = clock.now
                UserDefaults.standard.set(view.rawValue, forKey: SpendingChartView.key)
                await wait(for: "spending.loaded")
                report("spending, switch to \(view.title.lowercased()): \(ms(await settle() - start))\(loadingShown)")
            }
            navigator.screen = .money
            _ = await settle()
            try? await Task.sleep(for: .milliseconds(400))
            UserDefaults.standard.set(spendingView, forKey: SpendingChartView.key)

            // Memory as earlier runs measured it, before search reads every transaction.
            try? await Task.sleep(for: .seconds(3))
            report("idle memory before search: \(memoryMB()) MB (budget 200)")

            // ⌘K over Money: opening reads everything searchable; each keystroke
            // searches all of it.
            seen.remove("search.loaded")
            var start = clock.now
            navigator.isSearching = true
            await wait(for: "search.loaded")
            report("open search: \(ms(await settle() - start)) (budget 150)")
            for typed in ["m", "me", "merchant", "merchant 12"] {
                try? await Task.sleep(for: .milliseconds(300))
                seen.remove("search.results")
                start = clock.now
                NotificationCenter.default.post(name: .perfSearchText, object: typed)
                await wait(for: "search.results")
                report("search \"\(typed)\": \(ms(await settle() - start)) (budget 100)")
            }
            navigator.isSearching = false
            try? await Task.sleep(for: .milliseconds(400))

            UserDefaults.standard.set(TimeRange.all.rawValue, forKey: "netWorth.range")
            for view in NetWorthChartView.allCases {
                let start = clock.now
                UserDefaults.standard.set(view.rawValue, forKey: NetWorthChartView.key)
                report("switch to \(view.title): \(ms(await settle() - start)) (budget 100)")
                try? await Task.sleep(for: .milliseconds(300))
            }
            UserDefaults.standard.set(NetWorthChartView.total.rawValue, forKey: NetWorthChartView.key)
            for range in TimeRange.allCases {
                let start = clock.now
                UserDefaults.standard.set(range.rawValue, forKey: "netWorth.range")
                report("range \(range.rawValue): \(ms(await settle() - start)) (budget 100)")
                try? await Task.sleep(for: .milliseconds(300))
            }

            try? await Task.sleep(for: .seconds(3))
            report("idle memory after search: \(memoryMB()) MB (budget 200)")
            exit(0)
        }

        private var processStart: Date {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            sysctl(&mib, 4, &info, &size, nil, 0)
            let start = info.kp_proc.p_un.__p_starttime
            return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        }

        private func memoryMB() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
        }
    }

    /// When the main thread last finished a stretch of work, from its run loop:
    /// awake from `afterWaiting`, done at `beforeWaiting`, after the display
    /// cycle's layout and drawing.
    nonisolated final class MainThreadWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var awakeSince: ContinuousClock.Instant? = .now
        private var lastWorkEnd = ContinuousClock.now
        private var busyTotal = Duration.zero
        private var wakes = 0
        private var longest = Duration.zero
        private var observer: CFRunLoopObserver?

        func start() {
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            // Last of the before-waiting observers, so after Core Animation's commit.
            observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { [weak self] _, activity in
                self?.ran(activity)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        private func ran(_ activity: CFRunLoopActivity) {
            let now = ContinuousClock.now
            lock.withLock {
                if activity == .afterWaiting {
                    awakeSince = now
                } else {
                    if let awakeSince {
                        busyTotal += now - awakeSince
                        wakes += 1
                        longest = max(longest, now - awakeSince)
                    }
                    // A brief wake (a timer, a poll, one frame of an AppKit
                    // animation) isn't the work being timed.
                    if let awakeSince, now - awakeSince > .milliseconds(2) { lastWorkEnd = now }
                    awakeSince = nil
                }
            }
        }

        /// How long the main thread has spent awake in all, to compare before and after.
        var busy: Duration { lock.withLock { busyTotal } }

        /// Starts counting wakes and the longest one afresh.
        func resetStretches() {
            lock.withLock {
                wakes = 0; longest = .zero
            }
        }

        /// How many times the main thread woke since `resetStretches`, and its
        /// longest stretch of work: past a frame (8 ms at 120 Hz) it drops frames.
        var stretches: (wakes: Int, longest: Duration) { lock.withLock { (wakes, longest) } }

        /// Blocks until the main thread has been waiting `idle` since its last
        /// stretch of work, and returns when that stretch ended. Not for the
        /// main thread. Gives up after 10 s (something kept the main thread
        /// busy, such as an endless animation) and returns the time it gave up,
        /// so the timing shows it rather than the run hanging.
        func workEnd(idleFor idle: Duration) -> ContinuousClock.Instant {
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                let now = ContinuousClock.now
                if now > deadline { return now }
                let end: ContinuousClock.Instant? = lock.withLock {
                    awakeSince == nil && now - lastWorkEnd >= idle ? lastWorkEnd : nil
                }
                if let end { return end }
                usleep(1_000)
            }
        }
    }

    extension Duration {
        var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
    }
#endif
