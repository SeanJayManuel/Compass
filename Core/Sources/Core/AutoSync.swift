import Foundation

public struct SyncAttempt: Hashable, Sendable {
    public var startedAt: Date
    public var succeeded: Bool

    public init(startedAt: Date, succeeded: Bool) {
        self.startedAt = startedAt
        self.succeeded = succeeded
    }
}

/// When to sync without being asked: once a day, when the app opens or unlocks.
public enum AutoSync {
    /// Automatic attempts stop well short of the Bridge's 24 requests a day,
    /// leaving room for Sync Now.
    public static let dailyAttemptLimit = 12
    public static let retryAfterFailure: TimeInterval = 3600

    public static func shouldSync(attempts: [SyncAttempt], connected: Bool, now: Date, timeZone: TimeZone) -> Bool {
        guard connected else { return false }
        let today = Day(now, in: timeZone)
        if attempts.contains(where: { $0.succeeded && Day($0.startedAt, in: timeZone) == today }) { return false }
        let lastDay = attempts.filter { now.timeIntervalSince($0.startedAt) < 86_400 }
        if lastDay.count >= dailyAttemptLimit { return false }
        if let latest = attempts.map(\.startedAt).max(), now.timeIntervalSince(latest) < retryAfterFailure { return false }
        return true
    }
}
