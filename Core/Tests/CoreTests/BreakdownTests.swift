import Core
import Foundation
import Testing

@Suite struct BreakdownTests {
    let day = Day(year: 2026, month: 10, day: 20)

    func account(_ name: String, _ accountClass: AccountClass, excluded: Bool = false, archivedOn: Day? = nil) -> Account {
        Account(
            name: name, accountClass: accountClass, source: .manual,
            excludedFromNetWorth: excluded, archivedOn: archivedOn)
    }

    @Test func accessibleLeavesOutRetirement() {
        let checking = account("Checking", .cash)
        let k401 = account("401(k)", .retirement)
        let card = account("Card", .debt)
        let breakdown = NetWorthSeries.breakdown(
            accounts: [checking, k401, card],
            snapshots: [
                BalanceSnapshot(accountID: checking.id, day: day, source: .manual, balance: 5000),
                BalanceSnapshot(accountID: k401.id, day: day, source: .manual, balance: 40000),
                BalanceSnapshot(accountID: card.id, day: day, source: .manual, balance: -800)
            ],
            through: day
        )
        #expect(breakdown.last?.total == 44200)
        #expect(breakdown.last?.accessible == 4200)
        #expect(breakdown.last?.byClass == [.cash: 5000, .retirement: 40000, .debt: -800])
    }

    @Test func anExcludedAccountIsNotCounted() {
        let checking = account("Checking", .cash)
        let closing = account("Old savings", .cash, excluded: true)
        let breakdown = NetWorthSeries.breakdown(
            accounts: [checking, closing],
            snapshots: [
                BalanceSnapshot(accountID: checking.id, day: day, source: .manual, balance: 5000),
                BalanceSnapshot(accountID: closing.id, day: day, source: .manual, balance: 300)
            ],
            through: day
        )
        #expect(breakdown.last?.total == 5000)
    }

    @Test func anArchivedAccountDropsOutFromItsArchiveDay() {
        let start = Day(year: 2026, month: 10, day: 1)
        let checking = account("Checking", .cash)
        let closed = account("Closed savings", .cash, archivedOn: Day(year: 2026, month: 10, day: 3))
        let breakdown = NetWorthSeries.breakdown(
            accounts: [checking, closed],
            snapshots: [
                BalanceSnapshot(accountID: checking.id, day: start, source: .manual, balance: 1000),
                BalanceSnapshot(accountID: closed.id, day: start, source: .manual, balance: 500)
            ],
            through: Day(year: 2026, month: 10, day: 4)
        )
        #expect(breakdown.map(\.total) == [1500, 1500, 1000, 1000])
    }

    @Test func snapshotsForUnknownAccountsAreIgnored() {
        let checking = account("Checking", .cash)
        let breakdown = NetWorthSeries.breakdown(
            accounts: [checking],
            snapshots: [
                BalanceSnapshot(accountID: checking.id, day: day, source: .manual, balance: 1000),
                BalanceSnapshot(accountID: UUID(), day: day, source: .manual, balance: 99)
            ],
            through: day
        )
        #expect(breakdown.last?.total == 1000)
    }

    @Test func aBreakdownSurvivesBeingSavedAndLoaded() throws {
        let checking = account("Checking", .cash)
        let breakdown = NetWorthSeries.breakdown(
            accounts: [checking],
            snapshots: [BalanceSnapshot(accountID: checking.id, day: day, source: .manual, balance: Decimal(string: "1234.56")!)],
            through: day
        )
        let data = try JSONEncoder().encode(breakdown)
        #expect(try JSONDecoder().decode([DailyBreakdown].self, from: data) == breakdown)
    }

    @Test func extendingABreakdownCarriesTheLastDayForward() {
        let start = DailyBreakdown(day: day, total: 10, accessible: 8, byClass: [.cash: 8, .retirement: 2])
        let extended = NetWorthSeries.extend([start], through: Day(ordinal: day.ordinal + 2))
        #expect(extended.map(\.day) == [day, Day(ordinal: day.ordinal + 1), Day(ordinal: day.ordinal + 2)])
        #expect(extended.last?.total == 10)
        #expect(extended.last?.byClass == [.cash: 8, .retirement: 2])
    }
}
