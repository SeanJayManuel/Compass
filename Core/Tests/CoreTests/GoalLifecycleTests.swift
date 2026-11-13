import Core
import Foundation
import Testing

@Suite struct GoalLifecycleTests {
    func values(_ totals: [Decimal]) -> [DailyTotal] {
        totals.enumerated().map { DailyTotal(day: Day(year: 2026, month: 10, day: $0.offset + 1), total: $0.element) }
    }

    @Test func achievingRecordsTheFirstDayAndValueAtOrPastTheTarget() {
        let goal = Goal(name: "$100K", kind: .netWorth, target: 100_000)
        let updated = GoalLifecycle.update(goal, measured: values([95_000, 100_400, 99_000, 102_000]))
        #expect(updated.status == .achieved(on: Day(year: 2026, month: 10, day: 2), value: 100_400))
    }

    @Test func notYetReachedStaysActive() {
        let goal = Goal(name: "$100K", kind: .netWorth, target: 100_000)
        #expect(GoalLifecycle.update(goal, measured: values([95_000, 99_999])).status == .active)
    }

    @Test func anAchievedGoalStaysAchievedWhenTheValueDips() {
        let achieved = GoalStatus.achieved(on: Day(year: 2026, month: 9, day: 1), value: 100_000)
        let goal = Goal(name: "$100K", kind: .netWorth, target: 100_000, status: achieved)
        #expect(GoalLifecycle.update(goal, measured: values([90_000])).status == achieved)
    }

    @Test func aRetiredGoalIsNeverAchieved() {
        let goal = Goal(name: "$100K", kind: .netWorth, target: 100_000, status: .retired(reason: "Changed plans"))
        #expect(GoalLifecycle.update(goal, measured: values([200_000])).status == .retired(reason: "Changed plans"))
    }

    @Test func aRangeGoalIsAchievedAtItsTargetNotItsMinimum() {
        let goal = Goal(name: "Emergency fund", kind: .netWorth, target: 25_000, targetMin: 22_000)
        #expect(GoalLifecycle.update(goal, measured: values([23_000])).status == .active)
    }

    @Test func aFIREGoalUsesItsSpendingTarget() {
        let goal = Goal(name: "FIRE", kind: .fire(annualSpending: 4_000, multiplier: 25), target: 0)
        #expect(GoalLifecycle.update(goal, measured: values([99_999])).status == .active)
        #expect(GoalLifecycle.update(goal, measured: values([100_000])).status != .active)
    }

    @Test(arguments: [
        (Decimal(100_000), Decimal(150_000)),
        (50_000, 75_000),
        (150_000, 200_000),
        (75_000, 100_000),
        (7_500, 10_000),
        (1_000_000, 1_500_000),
        (22_000, 25_000)
    ])
    func theSuccessorIsTheNextRoundNumber(target: Decimal, next: Decimal) {
        let goal = Goal(name: "Goal", kind: .netWorth, target: target)
        #expect(GoalLifecycle.successor(of: goal).target == next)
    }

    @Test func aSuccessorIsADraftLinkedToItsPredecessor() {
        let invested = Set([UUID()])
        let goal = Goal(
            name: "$100K invested", kind: .accountTotal(invested), target: 100_000,
            targetDate: Day(year: 2026, month: 12, day: 31),
            status: .achieved(on: Day(year: 2026, month: 10, day: 1), value: 100_200),
            reward: Reward(name: "Tudor Black Bay 54"))
        let next = GoalLifecycle.successor(of: goal)
        #expect(next.name == "$150K invested")
        #expect(next.kind == .accountTotal(invested))
        #expect(next.predecessorID == goal.id)
        #expect(next.status == .active)
        #expect(next.reward == nil)
        #expect(next.targetDate == nil)
    }

    @Test func retiringKeepsTheReason() {
        let goal = Goal(name: "$100K", kind: .netWorth, target: 100_000)
        #expect(GoalLifecycle.retire(goal, reason: "Bought a house instead").status == .retired(reason: "Bought a house instead"))
    }

    @Test func aChainRunsFromTheFirstGoalToThisOne() {
        let first = Goal(name: "$50K", kind: .netWorth, target: 50_000)
        let second = Goal(name: "$100K", kind: .netWorth, target: 100_000, predecessorID: first.id)
        let third = Goal(name: "$150K", kind: .netWorth, target: 150_000, predecessorID: second.id)
        let unrelated = Goal(name: "FIRE", kind: .netWorth, target: 1_000_000)
        #expect(GoalLifecycle.chain(endingWith: third, in: [unrelated, third, first, second]).map(\.name) == ["$50K", "$100K", "$150K"])
    }

    @Test func milestonesListReachedGoalsAndClaimedRewardsNewestFirst() {
        let first = Goal(
            name: "$50K", kind: .netWorth, target: 50_000,
            status: .achieved(on: Day(year: 2025, month: 1, day: 10), value: 50_100))
        let second = Goal(
            name: "$100K", kind: .netWorth, target: 100_000,
            status: .achieved(on: Day(year: 2025, month: 12, day: 10), value: 100_000),
            reward: Reward(name: "Watch", cost: 4_200, claimedOn: Day(year: 2026, month: 1, day: 5)),
            predecessorID: first.id)
        let active = Goal(name: "$150K", kind: .netWorth, target: 150_000, predecessorID: second.id)
        let retired = Goal(name: "Boat", kind: .netWorth, target: 80_000, status: .retired(reason: "No boat"))

        let events = GoalLifecycle.milestones(in: [first, active, retired, second])

        #expect(events.map(\.kind) == [.rewardClaimed, .reached, .reached])
        #expect(events.map(\.goal.name) == ["$100K", "$100K", "$50K"])
        #expect(events[1].monthsSincePrevious == 11)
        #expect(events[2].monthsSincePrevious == nil)
    }
}
