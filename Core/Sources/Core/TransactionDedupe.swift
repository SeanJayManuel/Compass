import Foundation

public struct DuplicatePair: Hashable, Sendable {
    public var imported: UUID
    public var synced: UUID

    public init(imported: UUID, synced: UUID) {
        self.imported = imported
        self.synced = synced
    }
}

/// While Monarch and SimpleFIN run side by side, the same purchase can arrive
/// once from each. A pair is an imported and a synced transaction on the same
/// account, for the same amount, posted within three days of each other.
/// Each transaction pairs at most once, closest days first.
public enum TransactionDedupe {
    public static let dayTolerance = 3

    public static func pairs(in transactions: [Transaction]) -> [DuplicatePair] {
        struct Key: Hashable { var account: UUID; var amount: Decimal }
        let imported = Dictionary(grouping: transactions.filter { $0.externalID.hasPrefix("monarch:") }) {
            Key(account: $0.accountID, amount: $0.amount)
        }
        var used = Set<UUID>()
        var pairs: [DuplicatePair] = []
        for synced in transactions.filter({ $0.externalID.hasPrefix("simplefin:") }).sorted(by: { $0.day < $1.day }) {
            let candidates = (imported[Key(account: synced.accountID, amount: synced.amount)] ?? [])
                .filter { !used.contains($0.id) && abs($0.day.ordinal - synced.day.ordinal) <= dayTolerance }
                .sorted { abs($0.day.ordinal - synced.day.ordinal) < abs($1.day.ordinal - synced.day.ordinal) }
            guard let match = candidates.first else { continue }
            used.insert(match.id)
            pairs.append(DuplicatePair(imported: match.id, synced: synced.id))
        }
        return pairs
    }
}
