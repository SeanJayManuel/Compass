import Core
import Foundation
import Testing

@Suite struct GoalProgressTests {
    let today = Day(year: 2026, month: 10, day: 20)
    let checking = Account(name: "Checking", accountClass: .cash, source: .manual)
    let brokerage = Account(name: "Brokerage", accountClass: .taxable, source: .manual)
    let k401 = Account(name: "401(k)", accountClass: .retirement, source: .manual)

    /// Balances three months ago and today for each account.
    func history(_ balances: [(Account, Decimal, Decimal)]) -> [BalanceSnapshot] {
        balances.flatMap { account, before, now in
            [
                BalanceSnapshot(accountID: account.id, day: today.addingMonths(-3), source: .manual, balance: before),
                BalanceSnapshot(accountID: account.id, day: today, source: .manual, balance: now)
            ]
        }
    }

    func evaluate(_ goal: Goal, _ balances: [(Account, Decimal, Decimal)]) -> GoalProgress {
        GoalProgress.evaluate(goal, accounts: [checking, brokerage, k401], snapshots: history(balances), today: today)
    }

    @Test func aNetWorthGoalMeasuresEverything() {
        let progress = evaluate(
            Goal(name: "$150K", kind: .netWorth, target: 150_000),
            [(checking, 20_000, 20_000), (brokerage, 50_000, 60_000), (k401, 40_000, 40_000)])
        #expect(progress.current == 120_000)
        #expect(progress.fraction == Decimal(string: "0.8"))
        #expect(progress.remaining == 30_000)
    }

    @Test func anAccountTotalGoalMeasuresOnlyItsAccounts() {
        let goal = Goal(name: "$100K invested", kind: .accountTotal([brokerage.id, k401.id]), target: 100_000)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 50_000, 60_000), (k401, 40_000, 40_000)])
        #expect(progress.current == 100_000)
        #expect(progress.standing == .reached)
    }

    @Test func aFIREGoalTargetsSpendingTimesTheMultiplierAndCountsInvestableAssets() {
        let goal = Goal(name: "FIRE", kind: .fire(annualSpending: 40_000, multiplier: 25), target: 0)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 50_000, 60_000), (k401, 40_000, 40_000)])
        #expect(progress.target == 1_000_000)
        #expect(progress.current == 100_000)
    }

    @Test func paceIsTheAverageMonthlyGainOverThreeMonths() {
        let progress = evaluate(
            Goal(name: "$150K", kind: .netWorth, target: 150_000),
            [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        #expect(progress.pacePerMonth == 3_000)
    }

    @Test func onTrackWhenThePaceReachesTheTargetByItsDate() {
        // $30K to go at $3K a month is 10 months; the date is 12 months out.
        let goal = Goal(name: "$110K", kind: .netWorth, target: 110_000, targetDate: today.addingMonths(12))
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        #expect(progress.standing == .onTrack)
        #expect(progress.neededPerMonth == 2_500)
        #expect(progress.projectedDate == Day(ordinal: today.ordinal + 304))  // 10 × 30.436875 days, rounded
    }

    /// Without a date, "on track" has nothing to measure against: a goal
    /// reads growing or not growing (round 3 re-audit).
    @Test func aGoalWithNoDateReadsGrowingNotOnTrack() {
        let undated = Goal(name: "$110K", kind: .netWorth, target: 110_000)
        let growing = evaluate(undated, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        #expect(growing.reading(dated: false) == .growing)
        let flat = evaluate(undated, [(checking, 20_000, 20_000), (brokerage, 60_000, 60_000)])
        #expect(flat.reading(dated: false) == .notGrowing)
        let dated = Goal(name: "$110K", kind: .netWorth, target: 110_000, targetDate: today.addingMonths(12))
        #expect(evaluate(dated, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)]).reading(dated: true) == .onTrack)
    }

    @Test func behindWhenThePaceIsTooSlow() {
        let goal = Goal(name: "$110K", kind: .netWorth, target: 110_000, targetDate: today.addingMonths(6))
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        #expect(progress.standing == .behind)
        #expect(progress.neededPerMonth == 5_000)
    }

    @Test func noProjectionWhenNotGrowing() {
        let goal = Goal(name: "$110K", kind: .netWorth, target: 110_000)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 60_000, 60_000)])
        #expect(progress.projectedDate == nil)
        #expect(progress.standing == .behind)
    }

    @Test func aPastTargetDateNeedsTheWholeRemainderNow() {
        let goal = Goal(name: "$110K", kind: .netWorth, target: 110_000, targetDate: today.addingMonths(-1))
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        #expect(progress.neededPerMonth == 30_000)
    }

    @Test func aRangeGoalReportsTheMinimumSeparately() {
        let goal = Goal(name: "Emergency fund", kind: .accountTotal([checking.id]), target: 25_000, targetMin: 22_000)
        let progress = evaluate(goal, [(checking, 23_000, 23_800)])
        #expect(progress.minimumReached)
        #expect(progress.standing != .reached)
        #expect(progress.fractionOfRange == Decimal(string: "0.6"))
    }

    @Test func aPaceTooSmallToMatterProjectsNothing() {
        // $20 a month toward $1M is more than a century: no date, not a crash.
        let goal = Goal(name: "FIRE", kind: .fire(annualSpending: 40_000, multiplier: 25), target: 0)
        let progress = evaluate(goal, [(brokerage, 59_940, 60_000)])
        #expect(progress.pacePerMonth == 20)
        #expect(progress.projectedDate == nil)
    }

    // MARK: Projection line (seam P7)

    @Test func theProjectionLineRunsFromTodayToTheTargetOnTheProjectedDay() throws {
        // $30K to go at $3K a month: the target is reached 304 days out.
        let goal = Goal(name: "$110K", kind: .netWorth, target: 110_000)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        let line = try #require(progress.projectionLine(today: today))
        #expect(
            line == [
                DailyTotal(day: today, total: 80_000),
                DailyTotal(day: Day(ordinal: today.ordinal + 304), total: 110_000)
            ])
    }

    @Test func aRangeGoalProjectsToItsTargetNotItsMinimum() throws {
        let goal = Goal(name: "Fund", kind: .accountTotal([checking.id]), target: 25_000, targetMin: 22_000)
        let progress = evaluate(goal, [(checking, 19_000, 20_000)])
        // $5K to go at about $333 a month.
        let line = try #require(progress.projectionLine(today: today))
        #expect(line.first == DailyTotal(day: today, total: 20_000))
        #expect(line.last?.total == 25_000)
        #expect(line.last?.day == progress.projectedDate)
    }

    @Test func aReachedGoalHasNoProjectionLine() {
        let goal = Goal(name: "$70K", kind: .netWorth, target: 70_000)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        #expect(progress.standing == .reached)
        #expect(progress.projectionLine(today: today) == nil)
    }

    @Test func aGoalWithNoPaceHasNoProjectionLine() {
        let goal = Goal(name: "$110K", kind: .netWorth, target: 110_000)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 60_000, 60_000)])
        #expect(progress.projectionLine(today: today) == nil)
    }

    @Test func aGoalThatIsShrinkingHasNoProjectionLine() {
        let goal = Goal(name: "$110K", kind: .netWorth, target: 110_000)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 70_000, 60_000)])
        #expect(progress.projectionLine(today: today) == nil)
    }

    @Test func aNinetyFiveYearProjectionIsNotDrawn() {
        // $900K to go at $790 a month is about 95 years: a date exists, but a chart shouldn't stretch to it.
        let goal = Goal(name: "FIRE", kind: .fire(annualSpending: 40_000, multiplier: 25), target: 0)
        let progress = evaluate(goal, [(brokerage, 97_630, 100_000)])
        #expect(progress.projectedDate != nil)
        #expect(progress.projectionLine(today: today) == nil)
    }

    @Test func theHorizonCanBeChanged() {
        // 10 months out: inside a year, outside six months.
        let goal = Goal(name: "$110K", kind: .netWorth, target: 110_000)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        #expect(progress.projectionLine(today: today, horizonMonths: 12) != nil)
        #expect(progress.projectionLine(today: today, horizonMonths: 6) == nil)
    }

    @Test func aProjectionExactlyAtTheHorizonIsDrawn() {
        // $60K to go at $3K a month is 20 months.
        let goal = Goal(name: "$140K", kind: .netWorth, target: 140_000)
        let progress = evaluate(goal, [(checking, 20_000, 20_000), (brokerage, 51_000, 60_000)])
        #expect(progress.projectionLine(today: today, horizonMonths: 20) != nil)
        #expect(progress.projectionLine(today: today, horizonMonths: 19) == nil)
    }
}
