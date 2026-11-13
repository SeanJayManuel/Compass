import Foundation

/// One posted transaction. Negative amounts are money out.
public struct Transaction: Hashable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var accountID: UUID
    public var day: Day
    public var amount: Decimal
    public var merchant: String
    public var statement: String
    /// Nil until filed.
    public var category: String?
    /// "monarch:<Id>" or "simplefin:<id>", for idempotent imports and syncs.
    public var externalID: String
    /// What they wrote about it.
    public var note: String = ""
    /// Not a usual charge (a flight home, a new laptop).
    public var oneOff = false
    /// Someone owes them for it: `reimbursableAmount` of it, or all of it when nil.
    public var reimbursable = false
    public var reimbursableAmount: Decimal?
    /// Its parts when split into categories (seam 43); empty when it isn't.
    public var splits: [TransactionSplit] = []
    /// The goal whose money paid for it (seam 44): `paidFromGoalAmount` of
    /// it, or all of it when nil.
    public var paidFromGoal: UUID?
    public var paidFromGoalAmount: Decimal?

    public init(
        id: UUID = UUID(),
        accountID: UUID,
        day: Day,
        amount: Decimal,
        merchant: String,
        statement: String = "",
        category: String? = nil,
        externalID: String
    ) {
        self.id = id
        self.accountID = accountID
        self.day = day
        self.amount = amount
        self.merchant = merchant
        self.statement = statement
        self.category = category
        self.externalID = externalID
    }

    /// What's owed back on money out, never more than it.
    public var owedBack: Decimal {
        guard reimbursable, amount < 0 else { return 0 }
        return min(max(reimbursableAmount ?? -amount, 0), -amount)
    }

    /// The amount as spending counts it: money out less what's owed back.
    public var spendingAmount: Decimal { amount + owedBack }

    /// Transactions saved before notes and flags read back without them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        day = try container.decode(Day.self, forKey: .day)
        amount = try container.decode(Decimal.self, forKey: .amount)
        merchant = try container.decode(String.self, forKey: .merchant)
        statement = try container.decodeIfPresent(String.self, forKey: .statement) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category)
        externalID = try container.decode(String.self, forKey: .externalID)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        oneOff = try container.decodeIfPresent(Bool.self, forKey: .oneOff) ?? false
        reimbursable = try container.decodeIfPresent(Bool.self, forKey: .reimbursable) ?? false
        reimbursableAmount = try container.decodeIfPresent(Decimal.self, forKey: .reimbursableAmount)
        splits = try container.decodeIfPresent([TransactionSplit].self, forKey: .splits) ?? []
        paidFromGoal = try container.decodeIfPresent(UUID.self, forKey: .paidFromGoal)
        paidFromGoalAmount = try container.decodeIfPresent(Decimal.self, forKey: .paidFromGoalAmount)
    }
}

public enum Merchant {
    /// A key that survives store numbers and casing: lowercased words, with
    /// all-digit words of three or more digits dropped. "CHIPOTLE 0412" and
    /// "Chipotle" both become "chipotle".
    public static func key(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { word in !(word.count >= 3 && word.allSatisfy(\.isNumber)) }
            .joined(separator: " ")
    }
}
