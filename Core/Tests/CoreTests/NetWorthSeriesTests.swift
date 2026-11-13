import Core
import Foundation
import Testing

@Suite struct NetWorthSeriesTests {
    let checking = UUID()

    @Test func oneAccountIsTheNetWorth() {
        let day = Day(year: 2026, month: 10, day: 20)
        let series = NetWorthSeries.daily(
            snapshots: [BalanceSnapshot(accountID: checking, day: day, source: .manual, balance: 1000)],
            through: day
        )
        #expect(series == [DailyTotal(day: day, total: 1000)])
    }

    @Test func balancesCarryForwardAndDebtsSubtract() {
        let card = UUID()
        let series = NetWorthSeries.daily(
            snapshots: [
                BalanceSnapshot(accountID: checking, day: oct(1), source: .manual, balance: 1000),
                BalanceSnapshot(accountID: card, day: oct(2), source: .simplefin, balance: -250),
                BalanceSnapshot(accountID: checking, day: oct(4), source: .manual, balance: 1200)
            ],
            through: oct(5)
        )
        #expect(series.map(\.total) == [1000, 750, 750, 950, 950])
        #expect(series.map(\.day) == [oct(1), oct(2), oct(3), oct(4), oct(5)])
    }

    @Test func aManualBalanceWinsOverASyncedOneOnTheSameDay() {
        let series = NetWorthSeries.daily(
            snapshots: [
                BalanceSnapshot(accountID: checking, day: oct(3), source: .manual, balance: 600),
                BalanceSnapshot(accountID: checking, day: oct(3), source: .simplefin, balance: 500)
            ],
            through: oct(3)
        )
        #expect(series.map(\.total) == [600])
    }

    @Test func nothingBeforeTheFirstSnapshot() {
        #expect(NetWorthSeries.daily(snapshots: [], through: oct(3)).isEmpty)
    }

    private func oct(_ day: Int) -> Day { Day(year: 2026, month: 10, day: day) }
}

/// One class's or one account's own line, as the Accounts cards draw it.
@Suite struct BalanceHistoryTests {
    let today = Day(year: 2026, month: 10, day: 21)

    func account(_ name: String, _ accountClass: AccountClass, archivedOn: Day? = nil) -> Account {
        Account(name: name, accountClass: accountClass, source: .manual, archivedOn: archivedOn)
    }

    @Test func anArchivedAccountsLineStopsAtItsLastBalanceNotTheDayItWasArchived() {
        // Closed in March 2024, archived from the editor today.
        let savings = account("Old savings", .cash, archivedOn: today)
        let series = NetWorthSeries.accountSeries(
            savings,
            snapshots: [
                BalanceSnapshot(accountID: savings.id, day: Day(year: 2024, month: 3, day: 1), source: .imported, balance: 5000),
                BalanceSnapshot(accountID: savings.id, day: Day(year: 2024, month: 3, day: 4), source: .imported, balance: 4200)
            ],
            through: today
        )
        #expect(series.first?.day == Day(year: 2024, month: 3, day: 1))
        #expect(series.last == DailyTotal(day: Day(year: 2024, month: 3, day: 4), total: 4200))
        #expect(series.count == 4)
    }

    @Test func aDebtsLineIsWhatsOwedAndAnOverpaidCardGoesBelowZero() {
        let card = account("Rewards card", .debt)
        let series = NetWorthSeries.accountSeries(
            card,
            snapshots: [
                BalanceSnapshot(accountID: card.id, day: Day(year: 2026, month: 10, day: 19), source: .simplefin, balance: -1240),
                BalanceSnapshot(accountID: card.id, day: Day(year: 2026, month: 10, day: 21), source: .simplefin, balance: 80)
            ],
            through: today
        )
        #expect(series.map(\.total) == [1240, 1240, -80])
    }

    @Test func aClassLineStartsWhenTheClassFirstHeldSomethingAndKeepsLaterZeros() {
        let checking = account("Checking", .cash)
        let card = account("Card", .debt)
        let breakdown = NetWorthSeries.breakdown(
            accounts: [checking, card],
            snapshots: [
                BalanceSnapshot(accountID: checking.id, day: Day(year: 2026, month: 10, day: 16), source: .manual, balance: 1000),
                BalanceSnapshot(accountID: card.id, day: Day(year: 2026, month: 10, day: 18), source: .manual, balance: -500),
                BalanceSnapshot(accountID: card.id, day: Day(year: 2026, month: 10, day: 19), source: .manual, balance: 0),
                BalanceSnapshot(accountID: card.id, day: Day(year: 2026, month: 10, day: 21), source: .manual, balance: -200)
            ],
            through: today
        )
        let debt = NetWorthSeries.classSeries(breakdown, for: .debt)
        // Paid off on the 19th: that $0 stays on the line.
        #expect(debt.map(\.total) == [500, 0, 0, 200])
        #expect(debt.first?.day == Day(year: 2026, month: 10, day: 18))
        #expect(NetWorthSeries.classSeries(breakdown, for: .cash).map(\.total) == [1000, 1000, 1000, 1000, 1000, 1000])
        #expect(NetWorthSeries.classSeries(breakdown, for: .retirement).isEmpty)
    }

    @Test func aBalanceRisingIsGoodNewsAndSoIsWhatsOwedFalling() {
        #expect(BalanceHistoryMeasure.balance.isGood(change: 300))
        #expect(!BalanceHistoryMeasure.balance.isGood(change: -300))
        #expect(BalanceHistoryMeasure.owed.isGood(change: -300))
        #expect(!BalanceHistoryMeasure.owed.isGood(change: 300))
    }

    @Test func whatsOwedBelowZeroReadsAsCredit() {
        #expect(BalanceHistoryMeasure.owed.reading(1240) == .owed(1240))
        #expect(BalanceHistoryMeasure.owed.reading(-80) == .inCredit(80))
        #expect(BalanceHistoryMeasure.owed.reading(0) == .owed(0))
        #expect(BalanceHistoryMeasure.balance.reading(-50) == .balance(-50))
    }

    @Test func aClassLineStillHoldsItsArchivedAccountsThatCountedAndHadABalance() {
        let checking = account("Checking", .cash)
        let oldSavings = account("Old savings", .cash, archivedOn: today)
        let neverUsed = account("Never used", .cash, archivedOn: today)
        var notCounted = account("Not counted", .cash, archivedOn: today)
        notCounted.excludedFromNetWorth = true
        let oldCard = account("Old card", .debt, archivedOn: today)
        let closingLater = account("Closing later", .cash, archivedOn: Day(year: 2026, month: 11, day: 1))
        let balance = LatestBalance(day: Day(year: 2024, month: 3, day: 4), source: .imported, balance: 5000)
        let latest = [checking.id: balance, oldSavings.id: balance, notCounted.id: balance, oldCard.id: balance, closingLater.id: balance]

        let included = NetWorthSeries.archivedInClassLine(
            [checking, oldSavings, neverUsed, notCounted, oldCard, closingLater], for: .cash, latest: latest, today: today
        )
        #expect(included.map(\.name) == ["Old savings"])
    }
}

@Suite struct ArchiveDayTests {
    let today = Day(year: 2026, month: 10, day: 21)

    @Test func anAccountStopsCountingTheDayAfterItsLastBalance() {
        #expect(
            NetWorthSeries.archiveDay(lastBalance: Day(year: 2024, month: 3, day: 1), today: today)
                == Day(year: 2024, month: 3, day: 2))
    }

    @Test func neverLaterThanToday() {
        #expect(NetWorthSeries.archiveDay(lastBalance: today, today: today) == today)
        #expect(NetWorthSeries.archiveDay(lastBalance: nil, today: today) == today)
    }
}
