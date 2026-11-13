import Core
import Foundation
import Testing

@Suite struct LifeGoalsTests {
    let today = Day(year: 2026, month: 10, day: 20)
    let q4 = Quarter(year: 2026, quarter: 4)

    // MARK: Periods

    @Test func daysFallInTheirQuarter() {
        #expect(Quarter(Day(year: 2026, month: 3, day: 31)) == Quarter(year: 2026, quarter: 1))
        #expect(Quarter(Day(year: 2026, month: 4, day: 1)) == Quarter(year: 2026, quarter: 2))
        #expect(Quarter(Day(year: 2026, month: 12, day: 31)) == q4)
    }

    @Test func theQuarterAfterQ4IsNextYearsQ1() {
        #expect(q4.next == Quarter(year: 2027, quarter: 1))
        #expect(q4.start == Day(year: 2026, month: 10, day: 1))
        #expect(q4.end == Day(year: 2026, month: 12, day: 31))
        #expect(q4.name == "Q4 2026")
    }

    @Test func aQuarterKnowsWhichDayOfItItIs() {
        #expect(q4.days == 92)
        #expect(q4.dayNumber(of: today) == 20)
        #expect(q4.dayNumber(of: Day(year: 2026, month: 10, day: 22)) == 22)
        #expect(q4.dayNumber(of: q4.start) == 1)
        #expect(q4.dayNumber(of: q4.end) == 92)
    }

    @Test func aLeapYearsFirstQuarterHasOneMoreDay() {
        let leap = Quarter(year: 2028, quarter: 1)
        let plain = Quarter(year: 2027, quarter: 1)
        #expect(leap.days == 91)
        #expect(plain.days == 90)
        #expect(leap.dayNumber(of: Day(year: 2028, month: 1, day: 1)) == 1)
        #expect(leap.dayNumber(of: Day(year: 2028, month: 3, day: 31)) == 91)
        #expect(plain.dayNumber(of: Day(year: 2027, month: 3, day: 31)) == 90)
    }

    @Test func aDayOutsideTheQuarterIsClampedToItsEdges() {
        #expect(q4.dayNumber(of: Day(year: 2026, month: 9, day: 30)) == 1)
        #expect(q4.dayNumber(of: Day(year: 2027, month: 1, day: 1)) == 92)
        #expect(Quarter(year: 2026, quarter: 3).days == 92)
        #expect(Quarter(year: 2026, quarter: 2).days == 91)
    }

    // MARK: Progress

    @Test(arguments: [
        (LifeProgress.checkbox(done: true), Decimal(1)),
        (.checkbox(done: false), 0),
        (.count(current: 3, target: 12), Decimal(string: "0.25")!),
        (.count(current: 15, target: 12), 1),
        (.percent(40), Decimal(string: "0.4")!),
        (.percent(140), 1)
    ])
    func everyKindOfProgressReadsAsAFraction(progress: LifeProgress, fraction: Decimal) {
        #expect(progress.fraction == fraction)
    }

    @Test func reachingTheTargetMarksAGoalDoneAndFallingBackReopensIt() {
        let goal = LifeGoal(title: "Read 12 books", period: .year(2026), progress: .count(current: 11, target: 12))
        let done = LifeGoals.setProgress(goal, to: .count(current: 12, target: 12), today: today)
        #expect(done.status == .done(on: today))
        let reopened = LifeGoals.setProgress(done, to: .count(current: 11, target: 12), today: today)
        #expect(reopened.status == .active)
    }

    // MARK: Rollup

    @Test func aResolutionWithQuarterGoalsAveragesThemLeavingOutDroppedAndCarried() {
        let resolution = LifeGoal(title: "Get fit", period: .year(2026), progress: .percent(0))
        let children = [
            LifeGoal(title: "Run 5K", period: .quarter(q4), progress: .checkbox(done: true), parentID: resolution.id),
            LifeGoal(title: "Gym 30x", period: .quarter(q4), progress: .count(current: 15, target: 30), parentID: resolution.id),
            LifeGoal(
                title: "Yoga", period: .quarter(q4), progress: .percent(0), status: .dropped(reason: "Injury", on: today),
                parentID: resolution.id),
            LifeGoal(
                title: "Swim", period: .quarter(Quarter(year: 2026, quarter: 3)), progress: .percent(10),
                status: .carriedOver(to: q4), parentID: resolution.id)
        ]
        #expect(LifeGoals.progress(of: resolution, children: children) == Decimal(string: "0.75")!)
    }

    @Test func aResolutionWithoutQuarterGoalsUsesItsOwnProgress() {
        let resolution = LifeGoal(title: "Learn French", period: .year(2026), progress: .percent(30))
        #expect(LifeGoals.progress(of: resolution, children: []) == Decimal(string: "0.3")!)
    }

    // MARK: Now and review

    @Test func nowShowsThisYearsResolutionsAndThisQuartersGoals() {
        let goals = [
            LifeGoal(title: "2026 resolution", period: .year(2026), progress: .percent(0)),
            LifeGoal(title: "2025 resolution", period: .year(2025), progress: .percent(0)),
            LifeGoal(title: "Q4 goal", period: .quarter(q4), progress: .percent(0)),
            LifeGoal(title: "Q3 goal", period: .quarter(Quarter(year: 2026, quarter: 3)), progress: .percent(0))
        ]
        let now = LifeGoals.now(goals, today: today)
        #expect(now.resolutions.map(\.title) == ["2026 resolution"])
        #expect(now.quarterGoals.map(\.title) == ["Q4 goal"])
    }

    @Test func nowLeavesOutGoalsLetGoOrCarriedOverSoTheRingMatchesTheRows() {
        let resolution = LifeGoal(title: "Get strong", period: .year(2026), progress: .percent(0))
        let goals = [
            resolution,
            LifeGoal(title: "Gym 36 times", period: .quarter(q4), progress: .count(current: 18, target: 36), parentID: resolution.id),
            LifeGoal(
                title: "Run a 10K", period: .quarter(q4), progress: .checkbox(done: true), status: .done(on: today),
                parentID: resolution.id),
            LifeGoal(
                title: "Yoga", period: .quarter(q4), progress: .percent(0), status: .dropped(reason: "Injury", on: today),
                parentID: resolution.id),
            LifeGoal(
                title: "Swim", period: .quarter(Quarter(year: 2026, quarter: 3)), progress: .percent(100),
                status: .done(on: Day(year: 2026, month: 9, day: 1)), parentID: resolution.id)
        ]
        let now = LifeGoals.now(goals, today: today)
        #expect(now.quarterGoals.map(\.title) == ["Gym 36 times", "Run a 10K"])
        #expect(LifeGoals.progress(of: resolution, children: now.quarterGoals) == Decimal(string: "0.75")!)
    }

    @Test func aQuarterInReviewListsItsUnfinishedActiveGoals() {
        let q3 = Quarter(year: 2026, quarter: 3)
        let goals = [
            LifeGoal(title: "Done", period: .quarter(q3), progress: .checkbox(done: true), status: .done(on: today)),
            LifeGoal(title: "Open", period: .quarter(q3), progress: .percent(50)),
            LifeGoal(title: "Dropped", period: .quarter(q3), progress: .percent(0), status: .dropped(reason: "No", on: today))
        ]
        #expect(LifeGoals.toReview(goals, quarter: q3).map(\.title) == ["Open"])
    }

    @Test func carryingOverKeepsTheOriginalAndStartsACopyNextQuarter() {
        let q3 = Quarter(year: 2026, quarter: 3)
        let parent = UUID()
        let goal = LifeGoal(title: "Gym 30x", period: .quarter(q3), progress: .count(current: 18, target: 30), parentID: parent)
        let (original, copy) = LifeGoals.carryOver(goal)
        #expect(original.status == .carriedOver(to: q4))
        #expect(copy.period == .quarter(q4))
        #expect(copy.progress == .count(current: 0, target: 30))
        #expect(copy.parentID == parent)
        #expect(copy.carriedFromID == goal.id)
        #expect(copy.status == .active)
    }

    @Test func droppingKeepsTheReason() {
        let goal = LifeGoal(title: "Yoga", period: .quarter(q4), progress: .percent(0))
        #expect(LifeGoals.drop(goal, reason: "Injury", today: today).status == .dropped(reason: "Injury", on: today))
    }

    // MARK: Milestones

    @Test func finishedGoalsAndDoneListItemsBecomeMilestonesNewestFirst() {
        let goals = [
            LifeGoal(
                title: "Run 5K", period: .quarter(q4), progress: .checkbox(done: true),
                status: .done(on: Day(year: 2026, month: 10, day: 5))),
            LifeGoal(title: "Open", period: .quarter(q4), progress: .percent(10))
        ]
        let list = [
            ListItem(title: "See the northern lights", addedOn: Day(year: 2025, month: 1, day: 1), doneOn: Day(year: 2026, month: 10, day: 12)),
            ListItem(title: "Learn to sail", addedOn: Day(year: 2025, month: 1, day: 1))
        ]
        let milestones = LifeGoals.milestones(goals: goals, list: list)
        #expect(milestones.map(\.title) == ["See the northern lights", "Run 5K"])
        #expect(milestones.map(\.day) == [Day(year: 2026, month: 10, day: 12), Day(year: 2026, month: 10, day: 5)])
    }

    // MARK: Linked to money

    @Test func aBetLinkedToNetWorthReadsItsProgressLive() {
        let bet = LifeGoal(title: "Hit $50,000 net worth", period: .year(2026), progress: .linked(.netWorth, target: 50_000))
        #expect(LifeGoals.fraction(of: bet, values: [.netWorth: 37_500]) == Decimal(string: "0.75")!)
        #expect(LifeGoals.fraction(of: bet, values: [:]) == 0)
    }

    @Test func aLinkedBetIsDoneTheFirstTimeTheValueReachesItsTargetAndStaysDone() {
        let bet = LifeGoal(title: "Hit $50,000 net worth", period: .year(2026), progress: .linked(.netWorth, target: 50_000))
        let reached = LifeGoals.refreshLinked([bet], values: [.netWorth: 50_500], today: today)
        #expect(reached.first?.status == .done(on: today))
        let dipped = LifeGoals.refreshLinked(reached, values: [.netWorth: 49_000], today: Day(ordinal: today.ordinal + 1))
        #expect(dipped.first?.status == .done(on: today))
    }

    @Test func aRollupCountsLinkedChildrenToo() {
        let resolution = LifeGoal(title: "Finances", period: .year(2026), progress: .percent(0))
        let child = LifeGoal(
            title: "Hit $75,000", period: .quarter(q4), progress: .linked(.netWorth, target: 75_000),
            parentID: resolution.id)
        #expect(LifeGoals.progress(of: resolution, children: [child], values: [.netWorth: 75_000]) == 1)
    }

    // MARK: Reflections

    @Test func loggingAStepAddsOneAndKeepsTheReflection() {
        let dates = LifeGoal(title: "Go on 5 dates", period: .quarter(q4), progress: .count(current: 2, target: 5))
        let logged = LifeGoals.log(dates, note: "Easy conversation, want a second date.", today: today)
        #expect(logged.progress == .count(current: 3, target: 5))
        #expect(logged.entries == [LifeEntry(day: today, note: "Easy conversation, want a second date.")])
    }

    @Test func loggingTheLastStepFinishesTheGoal() {
        let dates = LifeGoal(title: "Go on 5 dates", period: .quarter(q4), progress: .count(current: 4, target: 5))
        #expect(LifeGoals.log(dates, note: "", today: today).status == .done(on: today))
    }

    @Test func loggingANoteOnAReachedLinkedGoalLeavesItDoneOnTheDayItWasReached() {
        let reachedOn = Day(year: 2026, month: 10, day: 5)
        let bet = LifeGoal(
            title: "Hit $150K net worth", period: .quarter(q4), progress: .linked(.netWorth, target: 150_000),
            status: .done(on: reachedOn))
        let logged = LifeGoals.log(bet, note: "Celebrated", today: today)
        #expect(logged.status == .done(on: reachedOn))
        #expect(logged.entries == [LifeEntry(day: today, note: "Celebrated")])
    }

    // MARK: Editing

    @Test func raisingAFinishedCountsTargetReopensIt() {
        let gym = LifeGoal(
            title: "Gym 12 times", period: .quarter(q4), progress: .count(current: 12, target: 12),
            status: .done(on: Day(year: 2026, month: 10, day: 9)))
        var edited = gym
        edited.progress = .count(current: 12, target: 24)
        let saved = LifeGoals.applyEdit(edited, over: gym, values: [:], today: today)
        #expect(saved.status == .active)
        #expect(saved.progress == .count(current: 12, target: 24))
    }

    @Test func fixingALinkedTargetThatWasReachedByMistakeReopensIt() {
        let typo = LifeGoal(
            title: "Reach $150K net worth", period: .year(2026), progress: .linked(.netWorth, target: 15_000),
            status: .done(on: today))
        var edited = typo
        edited.progress = .linked(.netWorth, target: 150_000)
        let saved = LifeGoals.applyEdit(edited, over: typo, values: [.netWorth: 148_557], today: today)
        #expect(saved.status == .active)
    }

    @Test func anEditKeepsADoneThatArrivedWhileTheEditorWasOpen() {
        let reachedOn = Day(year: 2026, month: 10, day: 18)
        let opened = LifeGoal(title: "Hit $150K", period: .quarter(q4), progress: .linked(.netWorth, target: 150_000))
        var stored = opened
        stored.status = .done(on: reachedOn)
        stored.entries = [LifeEntry(day: reachedOn, note: "Made it")]
        var edited = opened
        edited.title = "Hit $150K net worth"
        let saved = LifeGoals.applyEdit(edited, over: stored, values: [.netWorth: 151_000], today: today)
        #expect(saved.title == "Hit $150K net worth")
        #expect(saved.status == .done(on: reachedOn))
        #expect(saved.entries == stored.entries)
    }

    @Test func goalsAndListItemsSavedBeforeReflectionsAndYearsStillLoad() throws {
        let oldGoal =
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","note":"","period":{"year":{"_0":2026}},"progress":{"percent":{"_0":10}},"status":{"active":{}}}"#
        let goal = try JSONDecoder().decode(LifeGoal.self, from: Data(oldGoal.utf8))
        #expect(goal.entries.isEmpty)
        let oldItem = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Sail","addedOn":{"ordinal":9000}}"#
        let item = try JSONDecoder().decode(ListItem.self, from: Data(oldItem.utf8))
        #expect(item.year == nil)
    }
}

/// A year's bets, typed one per line on the vision card (Oct 30, 2026).
@Suite struct YearlyBetsTests {
    @Test func oneBetPerLineWithoutBulletsOrBlankLines() {
        #expect(
            YearlyBets.lines("- Savings: $100K net worth\n\n• Gym consistency \n* Local friendships\nCareer progress\n")
                == ["Savings: $100K net worth", "Gym consistency", "Local friendships", "Career progress"])
    }
}
