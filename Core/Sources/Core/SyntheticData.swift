import Foundation

/// Fake but realistic-sized balance history for timing tests. Deterministic,
/// so a slowdown is the code's fault, not the data's.
public enum SyntheticData {
    /// One snapshot per account per day for `years` years. Roughly one account
    /// in eight is a debt.
    public static func dailySnapshots(
        accounts: Int,
        years: Int,
        endingOn end: Day,
        seed: UInt64 = 42
    ) -> [BalanceSnapshot] {
        var random = SplitMix64(seed: seed)
        let days = years * 365 + years / 4
        let start = end.ordinal - days + 1

        var snapshots: [BalanceSnapshot] = []
        snapshots.reserveCapacity(accounts * days)
        for index in 0..<accounts {
            let id = UUID()
            let isDebt = index % 8 == 7
            var cents = Int64(random.next() % 5_000_000) + 100_000
            for ordinal in start...end.ordinal {
                cents = max(0, cents + Int64(random.next() % 20_001) - 9_000)
                let balance = Decimal(cents) / 100
                snapshots.append(
                    BalanceSnapshot(
                        accountID: id,
                        day: Day(ordinal: ordinal),
                        source: index % 3 == 0 ? .manual : .simplefin,
                        balance: isDebt ? -balance : balance
                    ))
            }
        }
        return snapshots
    }
}

private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
