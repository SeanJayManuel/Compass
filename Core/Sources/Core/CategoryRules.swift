import Foundation

/// One category per merchant and direction, learned from how transactions
/// were filed. Money in and money out from one merchant are separate rules:
/// lunch at Costco is eating out, a Costco paycheck is income.
public struct CategoryRules: Hashable, Sendable {
    private var byMerchant: [String: String]

    public init() { byMerchant = [:] }

    /// Rules as stored: rule key (`key(merchant:incoming:)`) to category.
    public init(_ rules: [String: String]) { byMerchant = rules }

    public var all: [String: String] { byMerchant }

    /// A money-out rule is keyed by the merchant alone, as before money in had
    /// rules of its own, so rules stored then stay money-out rules. Money in
    /// adds "+", which `Merchant.key` never produces.
    public static func key(merchant: String, incoming: Bool) -> String {
        (incoming ? "+" : "") + Merchant.key(merchant)
    }

    public static func key(for transaction: Transaction) -> String {
        key(merchant: transaction.merchant, incoming: transaction.amount > 0)
    }

    /// Each merchant gets the category it was filed under most; a tie goes to
    /// the most recent filing.
    public static func learn(from transactions: [Transaction]) -> CategoryRules {
        var counts: [String: [String: (count: Int, latest: Day)]] = [:]
        // A split's category is only its largest part, so it teaches nothing.
        for transaction in transactions where !transaction.isSplit {
            guard let category = transaction.category else { continue }
            let key = key(for: transaction)
            let current = counts[key, default: [:]][category] ?? (0, transaction.day)
            counts[key, default: [:]][category] = (current.count + 1, max(current.latest, transaction.day))
        }
        var rules = CategoryRules()
        for (merchant, categories) in counts {
            rules.byMerchant[merchant] =
                categories.max { a, b in
                    (a.value.count, a.value.latest) < (b.value.count, b.value.latest)
                }?.key
        }
        return rules
    }

    /// These rules, with merchants that have none learning from how they were
    /// filed, however they got there. Transfer categories teach nothing:
    /// moving money is about the occasion, not the merchant.
    public func filling(from history: [Transaction], skipping transfers: Set<String>) -> CategoryRules {
        let learned = Self.learn(from: history.filter { $0.category.map { !transfers.contains($0) } ?? false })
        return CategoryRules(byMerchant.merging(learned.byMerchant) { stored, _ in stored })
    }

    public func category(for merchant: String, incoming: Bool = false) -> String? {
        byMerchant[Self.key(merchant: merchant, incoming: incoming)]
    }

    /// Filing a transaction by hand sets the rule for its merchant, in its
    /// direction.
    public mutating func file(merchant: String, incoming: Bool = false, as category: String) {
        byMerchant[Self.key(merchant: merchant, incoming: incoming)] = category
    }

    /// A category name as typed, tidied: the ends trimmed and each run of
    /// spaces or tabs inside made one space.
    public static func tidy(_ typed: String) -> String {
        typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The category already in use that a typed name means: the same apart
    /// from case or spacing, so "software" files under Software rather than
    /// a twin that splits the budget. An exact match wins; otherwise the
    /// first in order, so twins from before always resolve the same way.
    /// Nil when the name is new.
    public static func existing(_ typed: String, among names: some Sequence<String>) -> String? {
        let name = tidy(typed)
        guard !name.isEmpty else { return nil }
        let key = name.lowercased()
        var match: String?
        for candidate in names where tidy(candidate).lowercased() == key {
            if candidate == name { return candidate }
            if match.map({ candidate < $0 }) ?? true { match = candidate }
        }
        return match
    }

    /// Files uncategorized transactions whose merchant has a rule for money
    /// moving their way.
    public func apply(to transactions: [Transaction]) -> [Transaction] {
        transactions.map { transaction in
            guard transaction.category == nil, let category = byMerchant[Self.key(for: transaction)] else { return transaction }
            var filed = transaction
            filed.category = category
            return filed
        }
    }
}
