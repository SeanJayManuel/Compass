import Foundation

/// What one sync changes: accounts SimpleFIN reports for the first time, and
/// one snapshot per reported account.
public struct SyncPlan: Hashable, Sendable {
    public var newAccounts: [Account]
    /// Keyed by account, day and source, so the store replaces an existing
    /// snapshot for the same key instead of adding a second one.
    public var snapshots: [BalanceSnapshot]
    /// Pins the bank has caught up with: a same-day sync within 1%.
    public var pinsToClear: [BalanceSnapshot] = []
}

public enum SyncMerge {
    /// Matches fetched accounts to existing ones by SimpleFIN ID, skips feeds
    /// merged into another account, and dates each
    /// balance on the day it falls on in `timeZone`. The Bridge can stamp a
    /// balance a few hours ahead (midnight UTC tomorrow), so nothing is dated
    /// after `today`.
    public static func plan(
        fetched: [SimpleFINAccount],
        existing: [Account],
        pins: [BalanceSnapshot] = [],
        timeZone: TimeZone,
        today: Day? = nil
    ) -> SyncPlan {
        let today = today ?? Day(.now, in: timeZone)
        var byExternalID = Dictionary(
            existing.compactMap { account in account.externalID.map { ($0, account.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        let merged = Set(existing.flatMap(\.mergedExternalIDs))
        var newAccounts: [Account] = []
        var snapshots: [BalanceSnapshot] = []
        for remote in fetched {
            let accountID: UUID
            if let known = byExternalID[remote.id] {
                accountID = known
            } else if merged.contains(remote.id) {
                continue
            } else {
                let account = Account(
                    name: remote.name,
                    institution: remote.institution,
                    accountClass: guessClass(remote),
                    source: .simplefin,
                    externalID: remote.id
                )
                newAccounts.append(account)
                byExternalID[remote.id] = account.id
                accountID = account.id
            }
            snapshots.append(
                BalanceSnapshot(
                    accountID: accountID,
                    day: min(Day(remote.balanceDate, in: timeZone), today),
                    source: .simplefin,
                    balance: remote.balance
                ))
        }
        let pinsByKey = Dictionary(
            pins.filter { $0.source == .manual }.map { (PinKey(accountID: $0.accountID, day: $0.day), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pinsToClear = snapshots.compactMap { synced -> BalanceSnapshot? in
            guard let pin = pinsByKey[PinKey(accountID: synced.accountID, day: synced.day)] else { return nil }
            return abs(synced.balance - pin.balance) <= abs(pin.balance) / 100 ? pin : nil
        }
        return SyncPlan(newAccounts: newAccounts, snapshots: snapshots, pinsToClear: pinsToClear)
    }
}

extension SyncMerge {
    /// Owed money is debt; otherwise the name says (an ESPP is equity, a Roth
    /// IRA retirement), and anything it doesn't place is cash.
    static func guessClass(_ remote: SimpleFINAccount) -> AccountClass {
        guard remote.balance >= 0 else { return .debt }
        let guess = MonarchBalanceImport.guessClass(from: remote.name)
        return guess == .otherAssets || guess == .debt ? .cash : guess
    }

    /// Where to start asking for transactions: 90 days back on the first sync
    /// (the Bridge's limit), then 30 days before the newest synced one, so a
    /// transaction an institution posts days late (a 401(k) buy, say) is
    /// still asked for. Ones already known are skipped by ID.
    public static func transactionWindowStart(lastSynced: Day?, today: Day) -> Day {
        let earliest = Day(ordinal: today.ordinal - 89)
        guard let lastSynced else { return earliest }
        return max(Day(ordinal: lastSynced.ordinal - 30), earliest)
    }

    /// Fetched transactions not seen before, on their accounts, dated on the
    /// local day they posted (never after today), and filed by the rules.
    public static func newTransactions(
        fetched: [SimpleFINAccount],
        accounts: [Account],
        knownExternalIDs: Set<String>,
        rules: CategoryRules,
        timeZone: TimeZone,
        today: Day
    ) -> [Transaction] {
        let byExternalID = Dictionary(
            accounts.compactMap { account in account.externalID.map { ($0, account.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        var new: [Transaction] = []
        for remote in fetched {
            guard let accountID = byExternalID[remote.id] else { continue }
            for transaction in remote.transactions {
                let externalID = "simplefin:\(remote.id):\(transaction.id)"
                guard !knownExternalIDs.contains(externalID) else { continue }
                new.append(
                    Transaction(
                        accountID: accountID,
                        day: min(Day(transaction.posted, in: timeZone), today),
                        amount: transaction.amount,
                        merchant: transaction.payee,
                        statement: transaction.description,
                        externalID: externalID
                    ))
            }
        }
        return rules.apply(to: new)
    }
}

private struct PinKey: Hashable {
    var accountID: UUID
    var day: Day
}
