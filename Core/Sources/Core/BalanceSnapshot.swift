import Foundation

public enum BalanceSource: String, Codable, Sendable {
    /// History brought in from a Monarch export.
    case imported
    case simplefin
    /// Typed by hand. On a synced account this is a pin.
    case manual

    /// When sources disagree about the same day, the higher rank wins: a pin
    /// beats the bank, and the bank beats imported history.
    var rank: Int {
        switch self {
        case .imported: 0
        case .simplefin: 1
        case .manual: 2
        }
    }
}

/// One account's balance on one day, from one source. Debts are negative.
public struct BalanceSnapshot: Hashable, Codable, Sendable {
    public var accountID: UUID
    public var day: Day
    public var source: BalanceSource
    public var balance: Decimal

    public init(accountID: UUID, day: Day, source: BalanceSource, balance: Decimal) {
        self.accountID = accountID
        self.day = day
        self.source = source
        self.balance = balance
    }
}
