import Core
import Foundation
import Testing

@Suite struct SyncMergeTests {
    let newYork = TimeZone(identifier: "America/New_York")!
    /// 2026-10-20 03:30 UTC, which is still Oct 19 in New York.
    let lateEvening = Date(timeIntervalSince1970: 1_792_467_000)
    let today = Day(year: 2026, month: 10, day: 20)

    var fetched: [SimpleFINAccount] {
        [
            SimpleFINAccount(
                id: "ACT-checking", name: "Everyday Checking", institution: "Example Bank",
                balance: Decimal(string: "1234.56")!, balanceDate: lateEvening),
            SimpleFINAccount(
                id: "ACT-card", name: "Rewards Card", institution: "Example Credit Union",
                balance: Decimal(string: "-321.09")!, balanceDate: lateEvening)
        ]
    }

    @Test func firstSyncAddsEachAccountWithItsBalanceOnTheLocalDay() throws {
        let plan = SyncMerge.plan(fetched: fetched, existing: [], timeZone: newYork, today: today)

        #expect(plan.newAccounts.map(\.name) == ["Everyday Checking", "Rewards Card"])
        #expect(plan.newAccounts.map(\.externalID) == ["ACT-checking", "ACT-card"])
        #expect(plan.newAccounts.allSatisfy { $0.source == .simplefin })

        let checking = try #require(plan.newAccounts.first)
        #expect(
            plan.snapshots.first
                == BalanceSnapshot(
                    accountID: checking.id, day: Day(year: 2026, month: 10, day: 19),
                    source: .simplefin, balance: Decimal(string: "1234.56")!
                ))
        #expect(plan.snapshots.count == 2)
    }

    @Test func syncingAgainAddsNoAccountsAndRewritesTheSameSnapshots() {
        let first = SyncMerge.plan(fetched: fetched, existing: [], timeZone: newYork, today: today)
        let manual = Account(name: "Watch collection", accountClass: .otherAssets, source: .manual)

        let second = SyncMerge.plan(fetched: fetched, existing: [manual] + first.newAccounts, timeZone: newYork, today: today)

        #expect(second.newAccounts.isEmpty)
        #expect(second.snapshots == first.snapshots)
    }

    @Test func aBalanceDatedInTheFutureCountsForToday() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let tomorrowMidnightUTC = Date(timeIntervalSince1970: 1_792_540_800)  // 2026-10-21 00:00 UTC, 09:00 in Tokyo
        let remote = SimpleFINAccount(
            id: "ACT-savings", name: "Savings", institution: nil,
            balance: 500, balanceDate: tomorrowMidnightUTC)

        let plan = SyncMerge.plan(
            fetched: [remote], existing: [], timeZone: tokyo,
            today: Day(year: 2026, month: 10, day: 20))

        #expect(plan.snapshots.map(\.day) == [Day(year: 2026, month: 10, day: 20)])
    }

    @Test func aNegativeBalanceIsFiledAsDebt() {
        let plan = SyncMerge.plan(fetched: fetched, existing: [], timeZone: newYork, today: today)
        #expect(plan.newAccounts.map(\.accountClass) == [.cash, .debt])
    }

    /// One brokerage reports one ESPP holding twice ("Manage" and "View"). Once
    /// the second is merged into the first, its feed is skipped: no account
    /// comes back and its balance isn't counted again.
    @Test func aFeedMergedIntoAnotherAccountIsSkipped() {
        let manage = Account(
            name: "Manage ESPP Shares", accountClass: .equity, source: .simplefin,
            externalID: "ACT-manage", mergedExternalIDs: ["ACT-view"])
        let feeds = [
            SimpleFINAccount(
                id: "ACT-manage", name: "Manage ESPP Shares", institution: "Example Brokerage",
                balance: 9000, balanceDate: lateEvening),
            SimpleFINAccount(
                id: "ACT-view", name: "View ESPP Shares", institution: "Example Brokerage",
                balance: 9000, balanceDate: lateEvening)
        ]
        let plan = SyncMerge.plan(fetched: feeds, existing: [manage], timeZone: newYork, today: today)
        #expect(plan.newAccounts.isEmpty)
        #expect(plan.snapshots.map(\.accountID) == [manage.id])
    }

    @Test func aNewAccountsClassIsGuessedFromItsName() {
        let feeds = [
            SimpleFINAccount(id: "A", name: "View Acme ESPP Shares", institution: nil, balance: 9000, balanceDate: lateEvening),
            SimpleFINAccount(id: "B", name: "Roth IRA", institution: nil, balance: 5000, balanceDate: lateEvening),
            SimpleFINAccount(id: "C", name: "Everyday Checking", institution: nil, balance: 100, balanceDate: lateEvening),
            SimpleFINAccount(id: "D", name: "Discover It", institution: nil, balance: 20, balanceDate: lateEvening)
        ]
        let plan = SyncMerge.plan(fetched: feeds, existing: [], timeZone: newYork, today: today)
        #expect(plan.newAccounts.map(\.accountClass) == [.equity, .retirement, .cash, .cash])
    }
}
