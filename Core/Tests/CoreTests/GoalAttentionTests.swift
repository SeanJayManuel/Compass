import Core
import Foundation
import Testing

@Suite struct GoalAttentionTests {
    let today = Day(year: 2026, month: 10, day: 20)

    /// A goal measuring one account, and the progress that account's balances
    /// (three months ago, today) give it.
    func measured(
        _ name: String, target: Decimal, date: Day? = nil, from before: Decimal, to now: Decimal,
        status: GoalStatus = .active
    ) -> (goal: Goal, progress: GoalProgress) {
        let account = Account(name: name, accountClass: .taxable, source: .manual)
        let snapshots = [
            BalanceSnapshot(accountID: account.id, day: today.addingMonths(-3), source: .manual, balance: before),
            BalanceSnapshot(accountID: account.id, day: today, source: .manual, balance: now)
        ]
        let goal = Goal(name: name, kind: .accountTotal([account.id]), target: target, targetDate: date, status: status)
        return (goal, GoalProgress.evaluate(goal, accounts: [account], snapshots: snapshots, today: today))
    }

    /// Orders the goals and returns their names.
    func order(_ entries: [(goal: Goal, progress: GoalProgress)], withoutProgress: [Goal] = []) -> [String] {
        let goals = entries.map(\.goal) + withoutProgress
        let progress = Dictionary(uniqueKeysWithValues: entries.map { ($0.goal.id, $0.progress) })
        return GoalAttention.order(goals, progress: progress).map(\.name)
    }

    // $60K now, up $9K in three months: $3K a month.
    func behindDated(_ name: String = "Behind a date") -> (goal: Goal, progress: GoalProgress) {
        // $50K to go is 17 months at $3K; the date is 6 months out.
        measured(name, target: 110_000, date: today.addingMonths(6), from: 51_000, to: 60_000)
    }

    func notGrowing(_ name: String = "Not growing") -> (goal: Goal, progress: GoalProgress) {
        measured(name, target: 110_000, from: 60_000, to: 60_000)
    }

    func onTrackDated(_ name: String, months: Int) -> (goal: Goal, progress: GoalProgress) {
        // $10K to go is about 3 months at $3K, well inside the date.
        measured(name, target: 70_000, date: today.addingMonths(months), from: 51_000, to: 60_000)
    }

    func growing(_ name: String, target: Decimal) -> (goal: Goal, progress: GoalProgress) {
        measured(name, target: target, from: 51_000, to: 60_000)
    }

    @Test func aGoalBehindItsDateComesBeforeEverythingElse() {
        let names = order([
            growing("Growing", target: 70_000),
            onTrackDated("On track", months: 12),
            notGrowing(),
            behindDated()
        ])
        #expect(names.first == "Behind a date")
    }

    @Test func eachBandComesAfterTheOneThatNeedsMoreAttention() {
        let names = order([
            growing("4 Growing", target: 70_000),
            onTrackDated("3 On track", months: 12),
            notGrowing("2 Not growing"),
            behindDated("1 Behind a date")
        ])
        #expect(names == ["1 Behind a date", "2 Not growing", "3 On track", "4 Growing"])
    }

    @Test func aGoalGrowingButPastTheProjectionCapIsNotCalledNotGrowing() {
        // $3K a month toward $10M is far beyond the 1,200-month projection cap,
        // so there is no projected date and the evaluation calls it behind. It
        // is still growing, so it ranks with the undated goals, after the ones
        // that really are stuck.
        let pastTheCap = growing("A past the cap", target: 10_000_000)
        #expect(pastTheCap.progress.projectedDate == nil)
        #expect(pastTheCap.progress.standing == .behind)
        #expect((pastTheCap.progress.pacePerMonth ?? 0) > 0)

        let names = order([
            pastTheCap,
            growing("B near", target: 70_000),
            notGrowing("C not growing")
        ])
        #expect(names == ["C not growing", "B near", "A past the cap"])
    }

    @Test func aGoalWithNoPaceYetStillCountsAsNotGrowing() {
        // One balance, so no pace and no projection: nothing says it is growing.
        let account = Account(name: "New", accountClass: .taxable, source: .manual)
        let goal = Goal(name: "New", kind: .accountTotal([account.id]), target: 100_000)
        let progress = GoalProgress.evaluate(
            goal, accounts: [account],
            snapshots: [BalanceSnapshot(accountID: account.id, day: today, source: .manual, balance: 5_000)],
            today: today)
        #expect(progress.pacePerMonth == nil)
        #expect(order([(goal, progress), growing("Growing", target: 70_000)]) == ["New", "Growing"])
    }

    @Test func goalsOnTrackForADateGoByTheNearestDate() {
        let names = order([
            onTrackDated("A later", months: 24),
            onTrackDated("Z sooner", months: 8),
            onTrackDated("M middle", months: 14)
        ])
        #expect(names == ["Z sooner", "M middle", "A later"])
    }

    @Test func undatedGoalsGoByTheNearestProjection() {
        // $10K to go reaches it in about 3 months; $30K to go in about 10.
        let names = order([
            growing("A far", target: 90_000),
            growing("Z near", target: 70_000)
        ])
        #expect(names == ["Z near", "A far"])
    }

    @Test func goalsThatTieGoByName() {
        let names = order([
            behindDated("Charlie"), behindDated("alpha"), behindDated("Bravo")
        ])
        #expect(names == ["alpha", "Bravo", "Charlie"])
    }

    @Test func notGrowingGoalsTieByNameToo() {
        let names = order([notGrowing("Zed"), notGrowing("Abe")])
        #expect(names == ["Abe", "Zed"])
    }

    @Test func aGoalWithNoProgressYetGoesLast() {
        let unmeasured = Goal(name: "Aardvark", kind: .netWorth, target: 50_000)
        let names = order([growing("Growing", target: 70_000), behindDated()], withoutProgress: [unmeasured])
        #expect(names == ["Behind a date", "Growing", "Aardvark"])
    }

    @Test func goalsWithNoProgressYetTieByName() {
        let names = order(
            [],
            withoutProgress: [
                Goal(name: "Beta", kind: .netWorth, target: 1), Goal(name: "Alpha", kind: .netWorth, target: 1)
            ])
        #expect(names == ["Alpha", "Beta"])
    }

    @Test func onlyActiveGoalsAreOrdered() {
        let reached = measured(
            "Reached", target: 50_000, from: 51_000, to: 60_000,
            status: .achieved(on: today.addingMonths(-1), value: 50_100))
        let retired = measured(
            "Retired", target: 110_000, date: today.addingMonths(6), from: 51_000, to: 60_000,
            status: .retired(reason: "Changed my mind"))
        let names = order([reached, retired, growing("Growing", target: 70_000)])
        #expect(names == ["Growing"])
    }

    @Test func anActiveGoalAtItsTargetCountsAsOnTrack() {
        // Between the data passing the target and the goal being marked reached.
        let atTarget = measured("At target", target: 60_000, from: 51_000, to: 60_000)
        let names = order([atTarget, behindDated()])
        #expect(names == ["Behind a date", "At target"])
    }

    @Test func noGoalsOrdersToNothing() {
        #expect(GoalAttention.order([], progress: [:]).isEmpty)
    }
}
