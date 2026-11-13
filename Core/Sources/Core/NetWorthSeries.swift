import Foundation

public struct DailyTotal: Hashable, Sendable {
    public var day: Day
    public var total: Decimal
    /// Opening balances in `total` so far: what accounts brought in when they
    /// were linked, which was already theirs. Changes leave it out. A goal that
    /// paid for things also counts here what it paid (`GoalFunding.available`),
    /// so its pace leaves spending out; it isn't an opening to show.
    public var opened: Decimal

    public init(day: Day, total: Decimal, opened: Decimal = 0) {
        self.day = day
        self.total = total
        self.opened = opened
    }

    /// The total less opening balances, which is what changes compare.
    public var withoutOpenings: Decimal { total - opened }
}

public enum NetWorthSeries {
    /// Net worth for every day from the first snapshot through `end`. Each
    /// account's last balance carries forward until a newer one arrives.
    public static func daily(snapshots: [BalanceSnapshot], through end: Day) -> [DailyTotal] {
        let byDay = Dictionary(grouping: snapshots, by: \.day)
        guard let start = byDay.keys.min(), start <= end else { return [] }

        var current: [UUID: Decimal] = [:]
        var total: Decimal = 0
        var series: [DailyTotal] = []
        series.reserveCapacity(end.ordinal - start.ordinal + 1)

        for ordinal in start.ordinal...end.ordinal {
            let day = Day(ordinal: ordinal)
            // A manual balance on a synced account is a pin: for the same day it
            // wins, so it's applied last.
            for snapshot in (byDay[day] ?? []).sorted(by: { $0.source.rank < $1.source.rank }) {
                total += snapshot.balance - (current[snapshot.accountID] ?? 0)
                current[snapshot.accountID] = snapshot.balance
            }
            series.append(DailyTotal(day: day, total: total))
        }
        return series
    }
}

/// One day's net worth, split the ways the Net Worth screen shows it.
public struct DailyBreakdown: Hashable, Codable, Sendable {
    public var day: Day
    public var total: Decimal
    /// Everything except retirement accounts.
    public var accessible: Decimal
    public var byClass: [AccountClass: Decimal]
    /// Opening balances counted so far, by class (see `DailyTotal.opened`).
    public var openedByClass: [AccountClass: Decimal]

    public init(
        day: Day, total: Decimal, accessible: Decimal, byClass: [AccountClass: Decimal],
        openedByClass: [AccountClass: Decimal] = [:]
    ) {
        self.day = day
        self.total = total
        self.accessible = accessible
        self.byClass = byClass
        self.openedByClass = openedByClass
    }

    public var opened: Decimal { openedByClass.values.reduce(0, +) }

    /// The day's net worth, with its opening balances.
    public var netWorth: DailyTotal { DailyTotal(day: day, total: total, opened: opened) }
}

extension NetWorthSeries {
    /// When archiving an account: it stops counting the day after its last
    /// balance, so a closed account's stale balance doesn't linger in net
    /// worth until the day it's archived. Never later than today.
    public static func archiveDay(lastBalance: Day?, today: Day) -> Day {
        guard let lastBalance else { return today }
        return min(Day(ordinal: lastBalance.ordinal + 1), today)
    }
}

extension NetWorthSeries {
    /// Money moved between two of their accounts (a matched transfer), dated
    /// the day it arrived.
    public struct Move: Hashable, Sendable {
        public var from: UUID
        public var to: UUID
        public var day: Day
        public var amount: Decimal

        public init(from: UUID, to: UUID, day: Day, amount: Decimal) {
            self.from = from
            self.to = to
            self.day = day
            self.amount = amount
        }
    }

    /// The transfers `TransferMatch` pairs, as moves between accounts.
    public static func moves(in transactions: [Transaction], kinds: [String: CategoryKind]) -> [Move] {
        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return TransferMatch.pairs(in: transactions, kinds: kinds).compactMap { pair in
            guard let out = byID[pair.outgoing], let into = byID[pair.incoming] else { return nil }
            return Move(from: out.accountID, to: into.accountID, day: into.day, amount: into.amount)
        }
    }
}

extension NetWorthSeries {
    /// Like `daily`, but per class, leaving out excluded accounts and dropping
    /// archived ones from their archive day on.
    ///
    /// Each account's first balance is an opening balance (`openedByClass`),
    /// except money `moves` brought into it from their other counted accounts
    /// by then, which those accounts' balances already lost.
    public static func breakdown(
        accounts: [Account], snapshots: [BalanceSnapshot], through end: Day,
        moves: [Move] = []
    ) -> [DailyBreakdown] {
        let counted = Dictionary(
            accounts.filter { !$0.excludedFromNetWorth }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let byDay = Dictionary(grouping: snapshots.filter { counted[$0.accountID] != nil }, by: \.day)
        guard let start = byDay.keys.min(), start <= end else { return [] }
        let archivals = Dictionary(grouping: counted.values.filter { $0.archivedOn != nil }, by: { $0.archivedOn! })

        var firstDay: [UUID: Day] = [:]
        for (day, snapshots) in byDay { for snapshot in snapshots { firstDay[snapshot.accountID] = min(firstDay[snapshot.accountID] ?? day, day) } }
        // Money moved in from an account that had balances by then, less money moved out to one.
        func movedIn(_ accountID: UUID, by day: Day) -> Decimal {
            moves.reduce(0) { sum, move in
                guard move.day <= day else { return sum }
                if move.to == accountID, let other = firstDay[move.from], other <= move.day { return sum + move.amount }
                if move.from == accountID, let other = firstDay[move.to], other <= move.day { return sum - move.amount }
                return sum
            }
        }

        var current: [UUID: Decimal] = [:]
        var byClass: [AccountClass: Decimal] = [:]
        var openedByClass: [AccountClass: Decimal] = [:]
        var opened = Set<UUID>()
        var series: [DailyBreakdown] = []
        series.reserveCapacity(end.ordinal - start.ordinal + 1)

        func set(_ accountID: UUID, to balance: Decimal?, on day: Day) {
            let accountClass = counted[accountID]!.accountClass
            byClass[accountClass, default: 0] += (balance ?? 0) - (current[accountID] ?? 0)
            current[accountID] = balance
            if let balance, opened.insert(accountID).inserted {
                openedByClass[accountClass, default: 0] += balance - movedIn(accountID, by: day)
            }
        }

        for ordinal in start.ordinal...end.ordinal {
            let day = Day(ordinal: ordinal)
            for snapshot in (byDay[day] ?? []).sorted(by: { $0.source.rank < $1.source.rank }) {
                if let archived = counted[snapshot.accountID]?.archivedOn, archived <= day { continue }
                set(snapshot.accountID, to: snapshot.balance, on: day)
            }
            for account in archivals[day] ?? [] {
                set(account.id, to: nil, on: day)
            }
            let total = byClass.values.reduce(0, +)
            series.append(
                DailyBreakdown(
                    day: day,
                    total: total,
                    accessible: total - (byClass[.retirement] ?? 0),
                    byClass: byClass.filter { $0.value != 0 },
                    openedByClass: openedByClass.filter { $0.value != 0 }
                ))
        }
        return series
    }
}

extension NetWorthSeries {
    /// Carries the last day forward through `end`: with no new balances, every
    /// later day is the same.
    public static func extend(_ breakdown: [DailyBreakdown], through end: Day) -> [DailyBreakdown] {
        guard var last = breakdown.last, last.day < end else { return breakdown }
        var extended = breakdown
        for ordinal in (last.day.ordinal + 1)...end.ordinal {
            last.day = Day(ordinal: ordinal)
            extended.append(last)
        }
        return extended
    }
}

/// What a class's or an account's own line measures. Debts are stored
/// negative so net worth is a plain sum; on their own they read better as
/// what's owed, where lower is better.
public enum BalanceHistoryMeasure: Hashable, Sendable {
    case balance
    case owed

    public init(_ accountClass: AccountClass) {
        self = accountClass == .debt ? .owed : .balance
    }

    /// From a stored balance to the value drawn: what's owed is positive, and
    /// an overpaid card goes below zero.
    public func drawn(_ stored: Decimal) -> Decimal {
        self == .owed ? -stored : stored
    }

    /// For a balance, up is good news; for what's owed, down is.
    public func isGood(change: Decimal) -> Bool {
        self == .owed ? change < 0 : change > 0
    }

    /// A drawn value, read the way it's labelled.
    public enum Reading: Hashable, Sendable {
        case balance(Decimal)
        case owed(Decimal)
        /// An overpaid card: below zero on an owed line.
        case inCredit(Decimal)
    }

    public func reading(_ drawn: Decimal) -> Reading {
        switch self {
        case .balance: .balance(drawn)
        case .owed: drawn < 0 ? .inCredit(-drawn) : .owed(drawn)
        }
    }
}

extension NetWorthSeries {
    /// One account's own line, in its measure: every day from its first
    /// balance through `today`. An archived account's line stops at its last
    /// balance, so a closed account archived long after doesn't draw a flat
    /// tail to today.
    public static func accountSeries(_ account: Account, snapshots: [BalanceSnapshot], through today: Day) -> [DailyTotal] {
        let own = snapshots.filter { $0.accountID == account.id }
        var end = today
        if let archivedOn = account.archivedOn, archivedOn <= today, let last = own.map(\.day).max() {
            end = min(today, last)
        }
        let measure = BalanceHistoryMeasure(account.accountClass)
        return daily(snapshots: own, through: end).map { DailyTotal(day: $0.day, total: measure.drawn($0.total)) }
    }

    /// One class's own daily total from the breakdown, in its measure,
    /// starting the first day it held anything, so a class added recently
    /// doesn't draw years of zero. Later zeros (a card paid off) stay.
    public static func classSeries(_ breakdown: [DailyBreakdown], for accountClass: AccountClass) -> [DailyTotal] {
        let measure = BalanceHistoryMeasure(accountClass)
        // The breakdown leaves a class out on days it totals zero.
        guard let first = breakdown.firstIndex(where: { ($0.byClass[accountClass] ?? 0) != 0 }) else { return [] }
        return breakdown[first...].map {
            DailyTotal(
                day: $0.day, total: measure.drawn($0.byClass[accountClass] ?? 0),
                opened: measure.drawn($0.openedByClass[accountClass] ?? 0))
        }
    }

    /// The archived accounts a class line still holds up to the day each was
    /// archived (as `breakdown` counts them): in the class, counted in net
    /// worth, and with a balance. Its card no longer lists them, so the line
    /// says so.
    public static func archivedInClassLine(
        _ accounts: [Account], for accountClass: AccountClass,
        latest: [UUID: LatestBalance], today: Day
    ) -> [Account] {
        accounts.filter { account in
            guard let archivedOn = account.archivedOn, archivedOn <= today else { return false }
            return account.accountClass == accountClass && !account.excludedFromNetWorth && latest[account.id] != nil
        }
    }
}
