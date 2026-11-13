import Core
import Foundation
import Testing

@Suite struct BudgetScheduleTests {
    let september = Month(year: 2026, month: 9)
    let october = Month(year: 2026, month: 10)
    let november = Month(year: 2026, month: 11)
    let december = Month(year: 2026, month: 12)

    var schedule: BudgetSchedule {
        BudgetSchedule(
            BudgetPlan(
                flexibleBudget: 2000, roles: ["Rent": .fixed], expected: ["Rent": 2100, "Internet": 70],
                plannedIncome: ["Paychecks": 5000]))
    }

    @Test func aChangeFromAMonthOnLeavesEarlierMonthsAlone() {
        let changed = schedule.setting(.bill("Internet"), to: 90, in: november, .onward)

        #expect(changed.plan(for: october).expected["Internet"] == 70)
        #expect(changed.plan(for: november).expected["Internet"] == 90)
        #expect(changed.plan(for: Month(year: 2027, month: 6)).expected["Internet"] == 90)
        #expect(changed.plan(for: november).expected["Rent"] == 2100)
    }

    @Test func aChangeForOneMonthLeavesTheNextAsItWas() {
        let changed = schedule.setting(.flexible, to: 2600, in: november, .onlyThisMonth)

        #expect(changed.plan(for: october).flexibleBudget == 2000)
        #expect(changed.plan(for: november).flexibleBudget == 2600)
        #expect(changed.plan(for: december).flexibleBudget == 2000)
        #expect(changed.plan(for: Month(year: 2027, month: 3)).flexibleBudget == 2000)
    }

    @Test func aChangeFromAMonthOnReplacesLaterChangesToThatAmountOnly() {
        let changed =
            schedule
            .setting(.bill("Internet"), to: 80, in: december, .onward)
            .setting(.flexible, to: 2500, in: december, .onward)
            .setting(.bill("Internet"), to: 90, in: november, .onward)

        #expect(changed.plan(for: december).expected["Internet"] == 90)
        #expect(changed.plan(for: december).flexibleBudget == 2500)
        #expect(changed.plan(for: november).flexibleBudget == 2000)
    }

    @Test func clearingAnAmountFromAMonthOnStopsPlanningIt() {
        let changed = schedule.setting(.income("Paychecks"), to: nil, in: november, .onward)

        #expect(changed.plan(for: october).plannedIncome["Paychecks"] == 5000)
        #expect(changed.plan(for: december).plannedIncome["Paychecks"] == nil)
    }

    @Test func aRoleChangeAppliesToEveryMonth() {
        let changed = schedule.setting(.flexible, to: 2600, in: november, .onward)
            .changing(december, .onward) { $0.roles["Internet"] = .flexible }

        #expect(changed.plan(for: september).role(of: "Internet") == .flexible)
        #expect(changed.plan(for: november).role(of: "Internet") == .flexible)
    }

    @Test func aMonthKnowsWhichAmountsItChanged() {
        let changed = schedule.setting(.bill("Internet"), to: 90, in: november, .onward)

        #expect(changed.differsFromMonthBefore(.bill("Internet"), in: november))
        #expect(!changed.differsFromMonthBefore(.bill("Internet"), in: december))
        #expect(!changed.differsFromMonthBefore(.bill("Rent"), in: november))
    }

    @Test func aChangeCanBeKeptToItsMonthAfterwards() {
        let changed = schedule.setting(.bill("Internet"), to: 90, in: november, .onward)
            .setting(.flexible, to: 2400, in: december, .onward)
            .keepingOnly(.bill("Internet"), in: november)

        #expect(changed.plan(for: november).expected["Internet"] == 90)
        #expect(changed.plan(for: december).expected["Internet"] == 70)
        #expect(changed.plan(for: december).flexibleBudget == 2400)
    }

    @Test func keepingAChangeToItsMonthLeavesALaterChangeAlone() {
        let february = Month(year: 2027, month: 2)
        let changed = schedule.setting(.bill("Internet"), to: 90, in: november, .onward)
            .setting(.bill("Internet"), to: 100, in: february, .onward)
            .keepingOnly(.bill("Internet"), in: november)

        #expect(changed.plan(for: december).expected["Internet"] == 70)
        #expect(changed.plan(for: Month(year: 2027, month: 1)).expected["Internet"] == 70)
        #expect(changed.plan(for: february).expected["Internet"] == 100)
    }

    @Test func aWholePlanFromAMonthOnChangesOnlyWhatDiffers() {
        var edited = schedule.plan(for: october)
        edited.flexibleBudget = 2200
        edited.expected["Internet"] = nil
        let changed = schedule.setting(.bill("Rent"), to: 2300, in: november, .onlyThisMonth)
            .applying(edited, from: october)

        #expect(changed.plan(for: november).expected["Rent"] == 2300)
        #expect(changed.plan(for: december).expected["Rent"] == 2100)
        #expect(changed.plan(for: december).flexibleBudget == 2200)
        #expect(changed.plan(for: november).expected["Internet"] == nil)
        #expect(changed.plan(for: september).expected["Internet"] == 70)
    }

    @Test func aRenameReachesEveryMonth() {
        let changed = schedule.setting(.bill("Internet"), to: 90, in: november, .onward)
            .renaming("Internet", to: "Phone & Internet")

        #expect(changed.plan(for: october).expected["Phone & Internet"] == 70)
        #expect(changed.plan(for: november).expected["Phone & Internet"] == 90)
        #expect(changed.plan(for: november).expected["Internet"] == nil)
    }

    @Test func aMergeThatDropsABillInAnyMonthSaysSo() {
        let changed = BudgetSchedule(BudgetPlan(flexibleBudget: 2000))
            .setting(.bill("Internet"), to: 90, in: november, .onward)

        #expect(changed.billDropped(merging: "Internet", into: "Shopping") == 90)
        #expect(changed.billDropped(merging: "Rent", into: "Shopping") == nil)
    }

    @Test func aScheduleIsEmptyOnlyWhenNoMonthPlansAnything() {
        let empty = BudgetSchedule(BudgetPlan(flexibleBudget: 0))
        #expect(empty.isEmpty)
        #expect(!empty.setting(.flexible, to: 500, in: december, .onlyThisMonth).isEmpty)
    }

    @Test func aPlanSavedBeforeMonthsExistedReadsBackAsEveryMonth() throws {
        let old = try JSONEncoder().encode(BudgetPlan(flexibleBudget: 1800, expected: ["Rent": 2100]))
        let read = try JSONDecoder().decode(BudgetSchedule.self, from: old)

        #expect(read.plan(for: november).flexibleBudget == 1800)
        #expect(read.plan(for: Month(year: 2020, month: 1)).expected["Rent"] == 2100)
    }

    @Test func aScheduleReadsBackWithItsMonths() throws {
        let changed = schedule.setting(.flexible, to: 2600, in: november, .onlyThisMonth)
        let read = try JSONDecoder().decode(BudgetSchedule.self, from: JSONEncoder().encode(changed))

        #expect(read == changed)
        #expect(read.plan(for: november).flexibleBudget == 2600)
    }

    @Test func aCategoryPlannedInAnyMonthIsKnown() {
        let changed = schedule.setting(.income("Bonus"), to: 3000, in: december, .onlyThisMonth)

        #expect(changed.categories == ["Rent", "Internet", "Paychecks", "Bonus"])
    }
}
