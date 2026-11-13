import Foundation

/// A pick's purchases at the shop it's from, for restocking (seam 37). The
/// shop is matched like Transactions search matches text, so a shop that
/// sells many things (Amazon, Target) counts everything bought there.
public enum PlaybookPurchases {
    /// The shop to match: a pick's "Where from" up to a comma, or the name
    /// in a web address: the last part before its ending ("uniqlo.com",
    /// "shop.uniqlo.com" and "uniqlo.co.uk" are all "uniqlo"). Nil when
    /// there's none.
    public static func shop(_ entry: PlaybookEntry) -> String? {
        guard entry.kind == .pick else { return nil }
        var text = String(entry.source.prefix { $0 != "," && $0 != "(" }).trimmingCharacters(in: .whitespaces)
        if !text.contains(" "), text.contains(".") {
            for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) { text.removeFirst(prefix.count) }
            var labels = text.prefix { $0 != "/" }.split(separator: ".").map(String.init)
            // Endings are short (com, co, uk, io); a name is rarely three letters or fewer.
            while labels.count > 1, let last = labels.last, last.count <= 3 { labels.removeLast() }
            text = labels.last ?? ""
        }
        return text.isEmpty ? nil : text
    }

    public struct Summary: Hashable, Sendable {
        public var shop: String
        public var lastBought: Day
        /// What the last purchase came to, as a positive amount.
        public var lastSpent: Decimal
        /// Purchases in the 365 days up to today.
        public var timesPastYear: Int
        /// The median days between purchases, once there are three or more.
        public var usualGapDays: Int?
        /// Longer since the last purchase than the usual gap.
        public var restockDue: Bool
    }

    /// Money out at the pick's shop, one purchase per day (charges on one day
    /// added up). Refunds, transfer and income categories, and unfiled
    /// transactions matched as transfers (`transfers`) aren't purchases. Nil
    /// with no shop or no purchases.
    public static func summary(
        _ entry: PlaybookEntry, transactions: [Transaction], kinds: [String: CategoryKind] = [:],
        transfers: Set<UUID> = [], today: Day
    ) -> Summary? {
        guard let shop = shop(entry) else { return nil }
        let bought = TransactionSearch.filter(transactions, TransactionQuery(text: shop)).filter { transaction in
            guard transaction.amount < 0, transaction.day <= today, !transfers.contains(transaction.id) else { return false }
            guard let category = transaction.category else { return true }
            return (kinds[category] ?? CategoryKind.guess(category)) == .spending
        }
        let byDay = Dictionary(grouping: bought, by: \.day).mapValues { $0.reduce(Decimal(0)) { $0 - $1.amount } }
        let days = byDay.keys.sorted()
        guard let last = days.last else { return nil }
        let gaps = zip(days, days.dropFirst()).map { $1.ordinal - $0.ordinal }.sorted()
        let usual = gaps.count >= 2 ? gaps[(gaps.count - 1) / 2] : nil
        return Summary(
            shop: shop, lastBought: last, lastSpent: byDay[last] ?? 0,
            timesPastYear: days.filter { $0.ordinal > today.ordinal - 365 }.count,
            usualGapDays: usual, restockDue: usual.map { today.ordinal - last.ordinal > $0 } ?? false)
    }
}
