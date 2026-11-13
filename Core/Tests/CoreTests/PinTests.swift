import Core
import Foundation
import Testing

/// The spec's rules for a manual balance (a pin) on a synced account.
@Suite struct PinTests {
    let today = Day(year: 2026, month: 10, day: 20)
    let utc = TimeZone(identifier: "UTC")!
    let checking = Account(name: "Checking", accountClass: .cash, source: .simplefin, externalID: "ACT-1")

    func fetched(_ balance: Decimal, on day: Day) -> SimpleFINAccount {
        SimpleFINAccount(
            id: "ACT-1", name: "Checking", institution: nil, balance: balance,
            balanceDate: day.startDate(in: utc))
    }

    func pin(_ balance: Decimal, on day: Day) -> BalanceSnapshot {
        BalanceSnapshot(accountID: checking.id, day: day, source: .manual, balance: balance)
    }

    @Test func aSameDaySyncWithinOnePercentClearsThePin() {
        let plan = SyncMerge.plan(
            fetched: [fetched(1005, on: today)], existing: [checking],
            pins: [pin(1000, on: today)], timeZone: utc, today: today)
        #expect(plan.pinsToClear == [pin(1000, on: today)])
    }

    @Test func aSameDaySyncFurtherAwayLeavesThePin() {
        let plan = SyncMerge.plan(
            fetched: [fetched(1011, on: today)], existing: [checking],
            pins: [pin(1000, on: today)], timeZone: utc, today: today)
        #expect(plan.pinsToClear.isEmpty)
    }

    @Test func pinsOnOtherDaysAreLeftAlone() {
        let yesterday = Day(ordinal: today.ordinal - 1)
        let plan = SyncMerge.plan(
            fetched: [fetched(1000, on: today)], existing: [checking],
            pins: [pin(1000, on: yesterday)], timeZone: utc, today: today)
        #expect(plan.pinsToClear.isEmpty)
    }

    @Test func aPinWinsOverASameDaySync() {
        let synced = BalanceSnapshot(accountID: checking.id, day: today, source: .simplefin, balance: 1200)
        let series = NetWorthSeries.daily(snapshots: [synced, pin(1000, on: today)], through: today)
        #expect(series.last?.total == 1000)
    }

    @Test func aNewerSyncTakesOverFromAPin() {
        let tomorrow = Day(ordinal: today.ordinal + 1)
        let synced = BalanceSnapshot(accountID: checking.id, day: tomorrow, source: .simplefin, balance: 1200)
        let series = NetWorthSeries.daily(snapshots: [pin(1000, on: today), synced], through: tomorrow)
        #expect(series.map(\.total) == [1000, 1200])
    }

    @Test func theBankWinsOverImportedHistoryOnTheSameDay() {
        let imported = BalanceSnapshot(accountID: checking.id, day: today, source: .imported, balance: 900)
        let synced = BalanceSnapshot(accountID: checking.id, day: today, source: .simplefin, balance: 950)
        #expect(NetWorthSeries.daily(snapshots: [synced, imported], through: today).last?.total == 950)
    }
}
