import Foundation

/// Money out of one of their accounts, and the same amount into another.
public struct TransferPair: Hashable, Sendable {
    public var outgoing: UUID
    public var incoming: UUID

    public init(outgoing: UUID, incoming: UUID) {
        self.outgoing = outgoing
        self.incoming = incoming
    }
}

/// Moving money between their own accounts (a card payment, savings, funding
/// the brokerage) is neither spending nor income. A transfer is money out of
/// one account and exactly the same amount into a different one within a few
/// business days, so an ACH move that spans a weekend still pairs. Each
/// transaction pairs at most once, closest days first.
public enum TransferMatch {
    /// Business days, not calendar days: Friday to Wednesday is three.
    public static let dayTolerance = 3
    /// Where matched transfers are filed. Its kind is transfer.
    public static let category = "Transfer"

    /// The uncategorized sides of every pair: what to file under `category`.
    /// Once filed, finding again files nothing new.
    public static func toFile(
        in transactions: [Transaction], kinds: [String: CategoryKind],
        within days: Int = dayTolerance
    ) -> Set<UUID> {
        let uncategorized = Set(transactions.filter { $0.category == nil }.map(\.id))
        return Set(pairs(in: transactions, kinds: kinds, within: days).flatMap { [$0.outgoing, $0.incoming] })
            .intersection(uncategorized)
    }

    /// The transactions with every matched, unfiled pair read as filed under
    /// `category`, so the budget leaves a card autopay and its "payment thank
    /// you" out before they file them. Nothing is saved; one-sided
    /// suggestions still count until they confirm them.
    public static func asFiled(_ transactions: [Transaction], kinds: [String: CategoryKind]) -> [Transaction] {
        asFiled(transactions, matched: toFile(in: transactions, kinds: kinds))
    }

    /// The same, with `toFile`'s answer already in hand.
    public static func asFiled(_ transactions: [Transaction], matched: Set<UUID>) -> [Transaction] {
        guard !matched.isEmpty else { return transactions }
        return transactions.map { transaction in
            guard matched.contains(transaction.id) else { return transaction }
            var filed = transaction
            filed.category = category
            return filed
        }
    }

    /// Uncategorized transactions with no partner whose wording reads like a
    /// move between accounts ("ONLINE TRANSFER TO SAV", "AUTOPAY", "PAYMENT
    /// THANK YOU"): transfers to or from an account Compass can't see. Only
    /// suggestions: the owner confirms each before it's filed. Payments to people
    /// (Zelle, Venmo, PayPal, Cash App) are spending, not transfers.
    public static func likelyOneSided(in transactions: [Transaction], kinds: [String: CategoryKind]) -> Set<UUID> {
        let paired = Set(pairs(in: transactions, kinds: kinds).flatMap { [$0.outgoing, $0.incoming] })
        return Set(
            transactions.filter { transaction in
                guard transaction.category == nil, !paired.contains(transaction.id) else { return false }
                let words = " " + Merchant.key(transaction.merchant + " " + transaction.statement) + " "
                if peopleApps.contains(where: { words.contains(" \($0) ") }) { return false }
                return transferWording.contains { words.contains(" \($0) ") }
            }.map(\.id))
    }

    static let transferWording = [
        "online transfer", "internal transfer", "mobile transfer", "ach transfer",
        "transfer to", "transfer from", "autopay", "auto pay", "payment thank you",
        "credit card payment", "card payment", "epay"
    ]
    static let peopleApps = ["zelle", "venmo", "paypal", "cash app", "cashapp"]

    /// Only uncategorized transactions, and ones already in a transfer-kind
    /// category, take part: anything filed as spending or income stays put.
    ///
    /// Sides already filed as transfers pair with each other first. Only the
    /// ones left over meet uncategorized transactions, so a new charge of
    /// the same amount can't take over a side that already has its partner
    /// (a $500 Venmo a day after a $500 move to savings stays spending).
    public static func pairs(
        in transactions: [Transaction], kinds: [String: CategoryKind],
        within days: Int = dayTolerance
    ) -> [TransferPair] {
        var filed: [Transaction] = []
        var uncategorized: [Transaction] = []
        for transaction in transactions {
            if let category = transaction.category {
                if (kinds[category] ?? CategoryKind.guess(category)) == .transfer { filed.append(transaction) }
            } else {
                uncategorized.append(transaction)
            }
        }
        var used = Set<UUID>()
        var pairs = match(filed, within: days, used: &used)
        let leftover = filed.filter { !used.contains($0.id) }
        pairs += match(leftover + uncategorized, within: days, used: &used) { out, into in
            out.category == nil || into.category == nil
        }
        return pairs
    }

    /// Greedy pairing, closest calendar days first, of transactions not yet
    /// in `used`; marks each side it pairs.
    private static func match(
        _ open: [Transaction], within days: Int, used: inout Set<UUID>,
        allowing allowed: (Transaction, Transaction) -> Bool = { _, _ in true }
    ) -> [TransferPair] {
        // Keyed by the amount's magnitude in cents, so 1500 and 1500.00 meet.
        let incoming = Dictionary(grouping: open.filter { $0.amount > 0 }) { cents($0.amount) }
        var candidates: [(distance: Int, outgoing: Transaction, incoming: Transaction)] = []
        for out in open where out.amount < 0 {
            for into in incoming[cents(-out.amount)] ?? []
            where into.accountID != out.accountID && into.amount == -out.amount && allowed(out, into) {
                guard businessDays(from: out.day, to: into.day) <= days else { continue }
                candidates.append((abs(into.day.ordinal - out.day.ordinal), out, into))
            }
        }
        candidates.sort {
            ($0.distance, $0.outgoing.day, $0.outgoing.externalID, $0.incoming.externalID)
                < ($1.distance, $1.outgoing.day, $1.outgoing.externalID, $1.incoming.externalID)
        }
        var pairs: [TransferPair] = []
        for candidate in candidates where !used.contains(candidate.outgoing.id) && !used.contains(candidate.incoming.id) {
            used.insert(candidate.outgoing.id)
            used.insert(candidate.incoming.id)
            pairs.append(TransferPair(outgoing: candidate.outgoing.id, incoming: candidate.incoming.id))
        }
        return pairs
    }

    /// Weekdays after the earlier day up to and including the later one:
    /// Friday to Monday is one, Saturday to Sunday none.
    public static func businessDays(from first: Day, to second: Day) -> Int {
        abs(weekdaysThrough(second.ordinal) - weekdaysThrough(first.ordinal))
    }

    /// The most calendar days a pair `days` business days apart can span,
    /// for reading enough history around a window.
    public static func maxCalendarDays(forBusinessDays days: Int) -> Int {
        days + 2 * ((days + 4) / 5)
    }

    /// Weekdays from day 0 (Monday, Jan 1 2001) through `ordinal`, counting
    /// back for days before it, so differences work either side.
    private static func weekdaysThrough(_ ordinal: Int) -> Int {
        let weeks = ordinal >= 0 ? ordinal / 7 : -((6 - ordinal) / 7)
        return weeks * 5 + min(ordinal - weeks * 7, 4)
    }

    private static func cents(_ amount: Decimal) -> Int {
        var scaled = amount * 100, rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
