import Foundation

public enum LockEvent: Sendable, CaseIterable {
    case unlocked
    case unlockFailed
    case systemSlept
    case screenLocked
    /// Lock Now (⌘L).
    case lockRequested
    /// The main window closed: Compass keeps running for its menu bar panel,
    /// so reopening the window counts as opening Compass again.
    case windowClosed
    /// A key press, click or scroll in Compass. Input in other apps doesn't count.
    case userActivity
    /// A periodic check, so idle time is noticed without any other event.
    case clockTick
}

/// When Compass asks for Touch ID (Settings > Security).
public enum LockMode: String, CaseIterable, Sendable {
    /// Never locks: the Mac's own login and FileVault protect it.
    case off
    /// Each time it opens (launch, or the window reopened); it stays unlocked while the window is open.
    case onLaunch
    /// At launch, when the Mac sleeps or its screen locks, and after `idleTimeout` without input.
    case afterSleepOrIdle
}

/// Decides whether Compass is locked. Unless the lock is off, it starts locked
/// and locks on Lock Now; in `.afterSleepOrIdle`
/// it also locks when the Mac sleeps or its screen locks, and after
/// `idleTimeout` without input.
public struct LockPolicy: Sendable {
    public private(set) var isLocked = true
    public var mode: LockMode
    /// Nil means never lock for idleness (Settings' "Never").
    public var idleTimeout: TimeInterval?
    private var lastActivity: Date

    public init(launchedAt: Date, mode: LockMode = .afterSleepOrIdle, idleTimeout: TimeInterval? = 15 * 60) {
        self.mode = mode
        self.idleTimeout = idleTimeout
        lastActivity = launchedAt
        isLocked = mode != .off
    }

    public mutating func handle(_ event: LockEvent, at now: Date) {
        switch event {
        case .unlocked:
            isLocked = false
            lastActivity = now
        case .unlockFailed:
            break
        case .systemSlept, .screenLocked:
            if mode == .afterSleepOrIdle { isLocked = true }
        case .lockRequested, .windowClosed:
            if mode != .off { isLocked = true }
        case .userActivity:
            if !isLocked { lastActivity = now }
        case .clockTick:
            if !isLocked, mode == .afterSleepOrIdle, let idleTimeout, now.timeIntervalSince(lastActivity) >= idleTimeout { isLocked = true }
        }
    }
}
