import Foundation

public enum Freshness: Hashable, Sendable {
    case current
    case stale(days: Int)
    case noBalance
}

/// When an account's newest balance is too old to trust. Synced accounts
/// should refresh daily; manual ones get logged now and then.
public enum Staleness {
    public static let syncedLimit = 7
    public static let manualLimit = 45

    public static func freshness(source: BalanceSource, lastUpdated: Day?, today: Day) -> Freshness {
        guard let lastUpdated else { return .noBalance }
        let age = today.ordinal - lastUpdated.ordinal
        let limit = source == .simplefin ? syncedLimit : manualLimit
        return age > limit ? .stale(days: age) : .current
    }
}

public struct LatestBalance: Hashable, Codable, Sendable {
    public var day: Day
    public var source: BalanceSource
    public var balance: Decimal

    public init(day: Day, source: BalanceSource, balance: Decimal) {
        self.day = day
        self.source = source
        self.balance = balance
    }
}

extension Staleness {
    /// Each account's newest balance. On the newest day, the same precedence
    /// as net worth applies, so a pin shows as the current balance.
    public static func latest(snapshots: [BalanceSnapshot]) -> [UUID: LatestBalance] {
        var latest: [UUID: LatestBalance] = [:]
        for snapshot in snapshots {
            if let current = latest[snapshot.accountID],
                (current.day, current.source.rank) >= (snapshot.day, snapshot.source.rank)
            {
                continue
            }
            latest[snapshot.accountID] = LatestBalance(day: snapshot.day, source: snapshot.source, balance: snapshot.balance)
        }
        return latest
    }
}

public enum SyncHealth: Hashable, Sendable {
    case healthy
    case lastSyncFailed(lastSuccess: Day?)
    /// No successful sync for more than a week.
    case overdue(days: Int)
}

extension Staleness {
    /// What the stale-data banner says, if anything. A broken sync should be
    /// visible instead of silent.
    public static func syncHealth(lastAttempt: Day?, lastAttemptFailed: Bool, lastSuccess: Day?, today: Day) -> SyncHealth {
        guard lastAttempt != nil else { return .healthy }
        if lastAttemptFailed { return .lastSyncFailed(lastSuccess: lastSuccess) }
        if let lastSuccess, today.ordinal - lastSuccess.ordinal > syncedLimit {
            return .overdue(days: today.ordinal - lastSuccess.ordinal)
        }
        return .healthy
    }
}
