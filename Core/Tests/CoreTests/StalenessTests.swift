import Core
import Foundation
import Testing

@Suite struct StalenessTests {
    let today = Day(year: 2026, month: 10, day: 20)
    func daysAgo(_ count: Int) -> Day { Day(ordinal: today.ordinal - count) }

    @Test func aSyncedAccountIsStaleAfterSevenDays() {
        #expect(Staleness.freshness(source: .simplefin, lastUpdated: daysAgo(7), today: today) == .current)
        #expect(Staleness.freshness(source: .simplefin, lastUpdated: daysAgo(8), today: today) == .stale(days: 8))
    }

    @Test func aManualAccountIsStaleAfterFortyFiveDays() {
        #expect(Staleness.freshness(source: .manual, lastUpdated: daysAgo(45), today: today) == .current)
        #expect(Staleness.freshness(source: .manual, lastUpdated: daysAgo(46), today: today) == .stale(days: 46))
    }

    @Test func anAccountWithNoBalanceHasNone() {
        #expect(Staleness.freshness(source: .manual, lastUpdated: nil, today: today) == .noBalance)
    }

    @Test func theLatestBalanceIsTheNewestDayWithAPinWinningThatDay() {
        let id = UUID()
        let latest = Staleness.latest(snapshots: [
            BalanceSnapshot(accountID: id, day: daysAgo(3), source: .simplefin, balance: 100),
            BalanceSnapshot(accountID: id, day: daysAgo(1), source: .simplefin, balance: 120),
            BalanceSnapshot(accountID: id, day: daysAgo(1), source: .manual, balance: 125)
        ])
        #expect(latest[id] == LatestBalance(day: daysAgo(1), source: .manual, balance: 125))
    }

    @Test func syncHealthIsQuietWhenTheLastSyncWorkedRecently() {
        #expect(Staleness.syncHealth(lastAttempt: daysAgo(1), lastAttemptFailed: false, lastSuccess: daysAgo(1), today: today) == .healthy)
    }

    @Test func aFailedLastSyncIsReported() {
        #expect(
            Staleness.syncHealth(lastAttempt: today, lastAttemptFailed: true, lastSuccess: daysAgo(3), today: today)
                == .lastSyncFailed(lastSuccess: daysAgo(3)))
    }

    @Test func noSuccessfulSyncForAWeekIsOverdue() {
        #expect(
            Staleness.syncHealth(lastAttempt: daysAgo(8), lastAttemptFailed: false, lastSuccess: daysAgo(8), today: today)
                == .overdue(days: 8))
    }

    @Test func neverSyncedIsNotAProblem() {
        #expect(Staleness.syncHealth(lastAttempt: nil, lastAttemptFailed: false, lastSuccess: nil, today: today) == .healthy)
    }
}
