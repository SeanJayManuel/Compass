import Foundation

public enum AccountClass: String, Codable, Sendable, CaseIterable {
    case cash
    case taxable
    case retirement
    case equity
    case otherAssets
    case debt
}

public struct Account: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var institution: String?
    public var accountClass: AccountClass
    public var source: BalanceSource
    /// The SimpleFIN account ID, for synced accounts.
    public var externalID: String?
    /// Tracked but not counted, like an account being closed.
    public var excludedFromNetWorth: Bool
    /// The day the account stopped counting. Its history stays.
    public var archivedOn: Day?
    /// SimpleFIN accounts merged into this one that report the same money
    /// (one brokerage lists a stock plan as "Manage" and "View"), so sync skips them.
    public var mergedExternalIDs: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        institution: String? = nil,
        accountClass: AccountClass,
        source: BalanceSource,
        externalID: String? = nil,
        excludedFromNetWorth: Bool = false,
        archivedOn: Day? = nil,
        mergedExternalIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.institution = institution
        self.accountClass = accountClass
        self.source = source
        self.externalID = externalID
        self.excludedFromNetWorth = excludedFromNetWorth
        self.archivedOn = archivedOn
        self.mergedExternalIDs = mergedExternalIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, institution, accountClass, source, externalID, excludedFromNetWorth, archivedOn, mergedExternalIDs
    }

    /// Backups from before merged feeds were remembered have none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        institution = try container.decodeIfPresent(String.self, forKey: .institution)
        accountClass = try container.decode(AccountClass.self, forKey: .accountClass)
        source = try container.decode(BalanceSource.self, forKey: .source)
        externalID = try container.decodeIfPresent(String.self, forKey: .externalID)
        excludedFromNetWorth = try container.decode(Bool.self, forKey: .excludedFromNetWorth)
        archivedOn = try container.decodeIfPresent(Day.self, forKey: .archivedOn)
        mergedExternalIDs = try container.decodeIfPresent([String].self, forKey: .mergedExternalIDs) ?? []
    }
}

extension AccountClass {
    /// Debts are stored negative so net worth is a plain sum. People type a
    /// debt as the amount owed, so a positive entry is flipped.
    public func storedBalance(entered: Decimal) -> Decimal {
        self == .debt ? -abs(entered) : entered
    }
}
