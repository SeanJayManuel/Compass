import AppKit
import Core
import LocalAuthentication
import Observation

/// Feeds system events into Core's LockPolicy and runs Touch ID, falling back
/// to the Mac password.
@Observable
final class AppLock {
    private(set) var isLocked = true
    private(set) var isAuthenticating = false
    /// Set when Touch ID is cancelled or fails, until the next unlock, so
    /// coming back to Compass doesn't ask again; the lock screen's button does.
    @ObservationIgnored private var declined = false

    private var policy = LockPolicy(launchedAt: .now, mode: LockSettings.mode, idleTimeout: LockSettings.idleTimeout)
    private(set) var mode = LockSettings.mode
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var timer: Timer?

    init() {
        isLocked = policy.isLocked
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, as: .systemSlept)
        observe(workspace, NSWorkspace.screensDidSleepNotification, as: .systemSlept)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, as: .screenLocked)
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), as: .screenLocked)
        // App Nap can hold back the timer while Compass is in the background,
        // so check idle time the moment it comes back.
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification, as: .clockTick)

        // A local monitor only sees input sent to Compass, which is the idle
        // definition we want.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.send(.userActivity)
            return event
        }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.clockTick) }
        }

        #if DEBUG
            // For driving the app in automated checks: starts unlocked, but only in a
            // debug build on sandbox data. Every relock still applies.
            if DataEnvironment.current == .sandbox, CommandLine.arguments.contains("--unlocked") {
                send(.unlocked)
            }
        #endif
    }

    /// Applies a new idle timeout from Settings.
    func setIdleTimeout(_ timeout: TimeInterval?) {
        policy.idleTimeout = timeout
    }

    /// Applies a new lock mode from Settings.
    func setMode(_ mode: LockMode) {
        policy.mode = mode
        self.mode = mode
    }

    /// Lock Now (⌘L).
    func lockNow() {
        send(.lockRequested)
    }

    /// The main window closed: Compass stays running for the menu bar panel,
    /// so it locks as if it had quit.
    func windowClosed() {
        send(.windowClosed)
    }

    /// Asks for Touch ID on its own: at launch and when Compass comes
    /// forward, unless they have already cancelled it since it locked.
    func unlockIfNotDeclined() async {
        guard !declined else { return }
        await unlock()
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let context = LAContext()
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock Compass")
            send(ok ? .unlocked : .unlockFailed)
            declined = !ok
        } catch {
            send(.unlockFailed)
            declined = true
        }
    }

    private func send(_ event: LockEvent) {
        policy.handle(event, at: .now)
        if isLocked != policy.isLocked { isLocked = policy.isLocked }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, as event: LockEvent) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(event) }
        }
        observers.append((center, token))
    }
}

/// The lock mode, defaulting to once per launch, and (in "After sleep or
/// idle") lock after N minutes idle; 0 means never. Defaults to 15.
enum LockSettings {
    static let modeKey = "lockMode"
    static let key = "lockAfterMinutes"
    static let choices = [1, 5, 15, 30, 60, 0]

    static var mode: LockMode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(LockMode.init(rawValue:)) ?? .onLaunch
    }

    static var idleTimeout: TimeInterval? {
        let minutes = UserDefaults.standard.object(forKey: key) as? Int ?? 15
        return minutes == 0 ? nil : TimeInterval(minutes * 60)
    }
}
