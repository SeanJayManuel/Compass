import Core
import Foundation
import Testing

@Suite struct BudgetSheetTests {
    let account = UUID()
    let october = Month(year: 2026, month: 10)

    func txn(_ category: String?, _ amount: Decimal, month: Int = 10, day: Int = 5) -> Transaction {
        Transaction(
            accountID: account, day: Day(year: 2026, month: month, day: day), amount: amount,
            merchant: "M", category: category, externalID: UUID().uuidString)
    }

    @Test func incomeIsPlannedAgainstWhatArrivedWithATotal() {
        let plan = BudgetPlan(flexibleBudget: 0, plannedIncome: ["Paychecks": 5000, "Interest": 20])
        let sheet = FlexBudget.sheet(
            october,
            transactions: [
                txn("Paychecks", 2600, day: 1), txn("Paychecks", 2600, day: 15), txn("Interest", 12),
                txn("Paychecks", 2500, month: 9)  // last month's
            ], kinds: [:], plan: plan)

        #expect(
            sheet.income.lines == [
                BudgetLine(category: "Paychecks", planned: 5000, actual: 5200),
                BudgetLine(category: "Interest", planned: 20, actual: 12)
            ])
        // Remaining is planned minus received: more than planned is negative.
        #expect(sheet.income.lines.map(\.remaining) == [-200, 8])
        #expect(sheet.income.planned == 5020)
        #expect(sheet.income.actual == 5212)
        // Extra pay doesn't stand in for interest still to come.
        #expect(sheet.income.outstanding == 8)
        #expect(sheet.income.overPlan == 200)
    }

    @Test func irregularSpendingStaysOutOfTheFlexiblePaceAndShowsApart() {
        // A card's annual fee and charity come when they come.
        let plan = BudgetPlan(
            flexibleBudget: 1_000, roles: ["Card Fee": .irregular, "Charity": .irregular],
            expected: ["Card Fee": 795], plannedIncome: ["Paychecks": 5_000])
        let transactions = [txn("Card Fee", -795), txn("Charity", -200), txn("Eating Out", -300), txn("Paychecks", 5_000)]
        let sheet = FlexBudget.sheet(october, transactions: transactions, kinds: [:], plan: plan)
        #expect(sheet.irregular.lines == [BudgetLine(category: "Card Fee", planned: 795, actual: 795)])
        #expect(sheet.irregular.unbudgeted == [BudgetLine(category: "Charity", planned: nil, actual: 200)])
        #expect(sheet.flexible.actual == 300)
        #expect(sheet.fixed.lines.isEmpty)
        #expect(sheet.actualNet == 3_705)  // 5,000 in, 300 flexible, 995 irregular
        #expect(sheet.leftToBudget == 3_205)  // 5,000 planned in, 1,000 flexible, 795 irregular
        let pace = FlexBudget.month(october, today: Day(year: 2026, month: 10, day: 31), transactions: transactions, kinds: [:], plan: plan)
        #expect(pace.flexibleSpent == 300)
        #expect(pace.bills.isEmpty)
    }

    @Test func fixedBillsArePlannedAgainstWhatWasPaidWithAGroupTotal() {
        let plan = BudgetPlan(flexibleBudget: 0, roles: ["Gym": .fixed], expected: ["Rent": 2100, "Internet": 70, "Gym": 50])
        let sheet = FlexBudget.sheet(
            october,
            transactions: [
                txn("Rent", -2100, day: 1), txn("Gym", -55, day: 3),
                txn("Internet", -70, month: 9, day: 28)  // paid last month, not yet this month
            ], kinds: [:], plan: plan)

        #expect(
            sheet.fixed.lines == [
                BudgetLine(category: "Rent", planned: 2100, actual: 2100),
                BudgetLine(category: "Internet", planned: 70, actual: 0),
                BudgetLine(category: "Gym", planned: 50, actual: 55)
            ])
        #expect(sheet.fixed.lines.map(\.remaining) == [0, 70, -5])
        #expect(sheet.fixed.planned == 2220)
        #expect(sheet.fixed.actual == 2155)
        #expect(sheet.fixed.outstanding == 70)
        #expect(sheet.fixed.overPlan == 5)
    }

    @Test func aFixedBillNoLongerPlannedStaysOnTheSheetToPlanAgain() {
        // The owner stopped planning Gas with nothing paid yet this month, and it
        // vanished with no way to add it back (Nov 7, 2026).
        let plan = BudgetPlan(
            flexibleBudget: 0, roles: ["Gas": .fixed, "Eating Out": .flexible, "Old": .fixed],
            expected: ["Rent": 2100])
        let sheet = FlexBudget.sheet(
            october, transactions: [txn("Rent", -2100, day: 1)],
            kinds: ["Gas": .spending, "Old": .transfer], plan: plan)
        #expect(sheet.fixed.lines == [BudgetLine(category: "Rent", planned: 2100, actual: 2100)])
        // Unbudgeted at $0; a fixed category that isn't spending doesn't show.
        #expect(sheet.fixed.unbudgeted == [BudgetLine(category: "Gas", planned: nil, actual: 0)])
        #expect(sheet.fixed.outstanding == 0)
    }

    @Test func anOverpaidBillDoesNotCoverAnUnpaidOne() {
        // Rent went up by $70 and internet isn't paid yet: the group still
        // has $70 to pay, not "All paid".
        let plan = BudgetPlan(flexibleBudget: 0, expected: ["Rent": 2100, "Internet": 70])
        let sheet = FlexBudget.sheet(october, transactions: [txn("Rent", -2170, day: 1)], kinds: [:], plan: plan)
        #expect(sheet.fixed.planned == 2170)
        #expect(sheet.fixed.actual == 2170)
        #expect(sheet.fixed.outstanding == 70)
        #expect(sheet.fixed.overPlan == 70)
        #expect(sheet.fixed.unbudgetedActual == 0)
    }

    @Test func unbudgetedBillsAreKeptApartFromWhatsLeftToPay() {
        // Every planned bill is paid; an $80 phone bill has no plan. That's
        // $80 unbudgeted, not "$80 over".
        let plan = BudgetPlan(flexibleBudget: 0, expected: ["Rent": 2100])
        let sheet = FlexBudget.sheet(
            october, transactions: [txn("Rent", -2100, day: 1), txn("Phone", -80)],
            kinds: [:], plan: plan)
        #expect(sheet.fixed.outstanding == 0)
        #expect(sheet.fixed.overPlan == 0)
        #expect(sheet.fixed.unbudgetedActual == 80)
        #expect(sheet.fixed.actual == 2180)
    }

    @Test func moneyInWithNoCategoryIsCountedApartFromIncome() {
        // A paycheck from a new payroll merchant arrives uncategorized. It
        // isn't income until it's filed, but the sheet says it's there.
        let plan = BudgetPlan(flexibleBudget: 1800, expected: ["Rent": 2100], plannedIncome: ["Paychecks": 5200])
        let sheet = FlexBudget.sheet(
            october,
            transactions: [
                txn(nil, 5200, day: 1), txn("Rent", -2100, day: 1), txn(nil, -300), txn(nil, 40, month: 9)
            ], kinds: [:], plan: plan)
        #expect(sheet.income.actual == 0)
        #expect(sheet.unfiledIn == 5200)
        #expect(sheet.flexible.actual == 300)
        #expect(FlexBudget.sheet(october, transactions: [], kinds: [:], plan: plan).unfiledIn == 0)
    }

    @Test func categoriesWithAnActualButNoPlanAreUnbudgeted() {
        let plan = BudgetPlan(flexibleBudget: 500, expected: ["Rent": 2100], plannedIncome: ["Paychecks": 5000])
        let sheet = FlexBudget.sheet(
            october,
            transactions: [
                txn("Paychecks", 5000), txn("Other Income", 300), txn("Business Income", 0),
                txn("Rent", -2100), txn("Phone", -80), txn("Insurance", -120), txn("Groceries", -200)
            ], kinds: [:], plan: plan)

        #expect(sheet.income.unbudgeted == [BudgetLine(category: "Other Income", planned: nil, actual: 300)])
        // Phone and Insurance guess as fixed bills, with nothing expected yet.
        #expect(sheet.fixed.unbudgeted.map(\.category) == ["Insurance", "Phone"])
        #expect(sheet.unbudgetedCount == 3)
        // Totals count the unbudgeted ones too; flexible categories share one
        // budget, so none of them is unbudgeted.
        #expect(sheet.income.actual == 5300)
        #expect(sheet.fixed.actual == 2300)
        #expect(sheet.fixed.planned == 2100)
    }

    @Test func flexibleSpendingSharesOneBudgetWithEachCategorysActual() {
        let plan = BudgetPlan(flexibleBudget: 1800, expected: ["Rent": 2100])
        let sheet = FlexBudget.sheet(
            october,
            transactions: [
                txn("Restaurants", -400), txn("Groceries", -300), txn("Groceries", 40), txn(nil, -25),
                txn("Rent", -2100), txn("Paychecks", 5000), txn("Transfer", -900), txn("Buy", -1000)
            ], kinds: [:], plan: plan)

        #expect(sheet.flexible.budget == 1800)
        #expect(sheet.flexible.actual == 685)
        #expect(sheet.flexible.remaining == 1115)
        #expect(
            sheet.flexible.lines == [
                BudgetLine(category: "Restaurants", planned: nil, actual: 400),
                BudgetLine(category: "Groceries", planned: nil, actual: 260),
                BudgetLine(category: Spending.uncategorized, planned: nil, actual: 25)
            ])
    }

    @Test func totalsLeaveTransfersOutAndSetIncomeAgainstExpenses() {
        let plan = BudgetPlan(flexibleBudget: 1800, expected: ["Rent": 2100, "Internet": 70], plannedIncome: ["Paychecks": 5000])
        let sheet = FlexBudget.sheet(
            october,
            transactions: [
                txn("Paychecks", 5200), txn("Rent", -2100), txn("Groceries", -600),
                txn("Credit Card Payment", -1500), txn("Transfer", 900), txn("Investments", -1000)
            ], kinds: [:], plan: plan)

        #expect(sheet.plannedExpenses == 3970)
        #expect(sheet.actualExpenses == 2700)
        #expect(sheet.plannedNet == 1030)
        #expect(sheet.actualNet == 2500)
    }

    @Test func everyPlannedDollarOfIncomeIsGivenAJob() {
        func sheet(income: Decimal, flexible: Decimal) -> BudgetSheet {
            FlexBudget.sheet(
                october, transactions: [], kinds: [:],
                plan: BudgetPlan(
                    flexibleBudget: flexible, expected: ["Rent": 2100, "Internet": 70], plannedIncome: ["Paychecks": income]))
        }

        // $440 left of a typed plan; balanced, flexible takes it.
        #expect(sheet(income: 5500, flexible: 2890).leftToBudget == 440)
        func balanced(income: Decimal) -> BudgetPlan {
            FlexBudget.balanced(
                BudgetPlan(
                    flexibleBudget: 2890, expected: ["Rent": 2100, "Internet": 70],
                    plannedIncome: ["Paychecks": income]), kinds: [:])
        }
        #expect(balanced(income: 5500).flexibleBudget == 3330)
        // Planned past income: flexible gives it back.
        #expect(sheet(income: 4000, flexible: 2890).leftToBudget == -1060)
        #expect(balanced(income: 4000).flexibleBudget == 1830)
        // Bills alone past income: flexible is $0.
        #expect(balanced(income: 2000).flexibleBudget == 0)
        // No income planned: nothing to give jobs to.
        #expect(sheet(income: 0, flexible: 500).leftToBudget == nil)
    }

    @Test func billsInCategoriesThatAreNoLongerSpendingLeaveTheSheet() {
        // An auto-invest kept as a bill from an older plan inflated planned
        // expenses and the emergency fund, and never showed as paid.
        let plan = BudgetPlan(
            flexibleBudget: 1800, roles: ["Investments": .fixed, "Pay Rent": .fixed, "Savings": .fixed],
            expected: ["Investments": 500, "Pay Rent": 2100, "Savings": 300])
        let sheet = FlexBudget.sheet(
            october, transactions: [txn("Investments", -500), txn("Pay Rent", -2100)],
            kinds: ["Savings": .transfer], plan: plan)
        #expect(sheet.fixed.lines == [BudgetLine(category: "Pay Rent", planned: 2100, actual: 2100)])
        #expect(sheet.emergencyFund.monthly == 2100)
        #expect(sheet.plannedExpenses == 3900)
    }

    @Test func theFixedPlanIsTheEmergencyFundBasis() {
        let plan = BudgetPlan(flexibleBudget: 1800, expected: ["Rent": 2100, "Internet": 70, "Phone": 927])
        let sheet = FlexBudget.sheet(october, transactions: [], kinds: [:], plan: plan)
        #expect(sheet.emergencyFund.monthly == 3097)
        #expect(sheet.emergencyFund.threeMonths == 9291)
        #expect(sheet.emergencyFund.sixMonths == 18582)
    }

    @Test func aTypedPlannedAmountIsReadStrictly() {
        #expect(BudgetPlan.amount(from: "$2,000") == 2000)
        #expect(BudgetPlan.amount(from: " 1800.50 ") == Decimal(string: "1800.50"))
        #expect(BudgetPlan.amount(from: "2k") == 2000)
        #expect(BudgetPlan.amount(from: "1.5K") == 1500)
        #expect(BudgetPlan.amount(from: "0") == 0)
        // The shared money field read "12abc" as $12 and "1.8k" as $1.80.
        #expect(BudgetPlan.amount(from: "12abc") == nil)
        #expect(BudgetPlan.amount(from: "") == nil)
        #expect(BudgetPlan.amount(from: "-50") == nil)
        // A stray point or a lone "k" isn't $0.
        #expect(BudgetPlan.amount(from: ".") == nil)
        #expect(BudgetPlan.amount(from: "k") == nil)
        #expect(BudgetPlan.amount(from: "$") == nil)
        #expect(BudgetPlan.amount(from: ".5") == Decimal(string: "0.5"))
    }

    @Test func renamingACategoryCarriesItsPlan() {
        let plan = BudgetPlan(flexibleBudget: 1800, roles: ["Misc": .fixed], expected: ["Misc": 20], plannedIncome: ["Pay": 5000])
        let renamed = plan.renaming("Misc", to: "Software").renaming("Pay", to: "Paychecks")
        #expect(
            renamed
                == BudgetPlan(
                    flexibleBudget: 1800, roles: ["Software": .fixed], expected: ["Software": 20],
                    plannedIncome: ["Paychecks": 5000]))
    }

    @Test func renamingKeepsARoleThatCameFromTheOldName() {
        // Internet was a bill only by its name's guess; Fiber guesses flexible,
        // so the bill dropped out of Fixed with its expected amount orphaned.
        let plan = BudgetPlan(flexibleBudget: 1800, expected: ["Internet": 70])
        let renamed = plan.renaming("Internet", to: "Fiber")
        #expect(renamed.role(of: "Fiber") == .fixed)
        #expect(renamed.expected == ["Fiber": 70])
        #expect(
            FlexBudget.sheet(october, transactions: [txn("Fiber", -70)], kinds: [:], plan: renamed).fixed.lines
                == [BudgetLine(category: "Fiber", planned: 70, actual: 70)])
        // Same guess either way: nothing needs pinning.
        #expect(BudgetPlan(flexibleBudget: 0).renaming("Misc", to: "Software").roles.isEmpty)
    }

    @Test func mergingABillIntoAFlexibleCategoryKeepsItsRoleAndDropsTheBill() {
        // Software already has transactions; folding a bill into it doesn't
        // change what Software is. Its $40 would sit in the plan unseen
        // (Software isn't a bill), so it goes, and the charges count as
        // flexible spending.
        let plan = BudgetPlan(flexibleBudget: 0, expected: ["Phone": 40])
        // The merge alert says so first.
        #expect(plan.billDropped(merging: "Phone", into: "Software") == 40)
        #expect(plan.billDropped(merging: "Phone", into: "Internet") == nil)
        let merged = plan.renaming("Phone", to: "Software", into: true)
        #expect(merged.roles.isEmpty)
        #expect(merged.expected.isEmpty)
        let pinned = BudgetPlan(flexibleBudget: 0, roles: ["Bills": .flexible], expected: ["Internet & Cable": 70])
        #expect(pinned.renaming("Internet & Cable", to: "Bills", into: true).expected.isEmpty)
    }

    @Test func mergingIntoAnExistingBillAddsTheAmountsAndKeepsItsRole() {
        // Utilities is a bill by its name; Water was pinned flexible.
        let plan = BudgetPlan(
            flexibleBudget: 0, roles: ["Water": .flexible],
            expected: ["Gas & Electric": 80, "Utilities": 60, "Water": 40])
        let merged = plan.renaming("Gas & Electric", to: "Utilities").renaming("Water", to: "Utilities")
        #expect(merged.expected == ["Utilities": 180])
        #expect(merged.roles.isEmpty)
        #expect(merged.role(of: "Utilities") == .fixed)
    }

    @Test func aPlanSavedBeforePlannedIncomeStillReadsBack() throws {
        let saved = #"{"flexibleBudget":1800,"roles":{"Gym":"fixed"},"expected":{"Rent":2100}}"#
        let plan = try JSONDecoder().decode(BudgetPlan.self, from: Data(saved.utf8))
        #expect(plan.flexibleBudget == 1800)
        #expect(plan.roles == ["Gym": .fixed])
        #expect(plan.expected == ["Rent": 2100])
        #expect(plan.plannedIncome.isEmpty)
    }

    @Test func aPlanWithFixedBillsButNoFlexibleBudgetIsStillABudget() {
        // Spending used to treat a $0 flexible budget as no budget at all: it
        // showed the setup prompt again and hid Edit Budget.
        #expect(!BudgetPlan(flexibleBudget: 0, expected: ["Rent": 2100]).isEmpty)
        #expect(!BudgetPlan(flexibleBudget: 0, plannedIncome: ["Paychecks": 5000]).isEmpty)
        #expect(!BudgetPlan(flexibleBudget: 1800).isEmpty)
        #expect(BudgetPlan(flexibleBudget: 0).isEmpty)
    }

    @Test func plannedIncomeSurvivesTheRoundTrip() throws {
        let plan = BudgetPlan(flexibleBudget: 1800, expected: ["Rent": 2100], plannedIncome: ["Paychecks": 5200])
        let back = try JSONDecoder().decode(BudgetPlan.self, from: JSONEncoder().encode(plan))
        #expect(back == plan)
    }
}

/// The flexible budget is what's left (round 4, one behavior for every
/// month): planned income less fixed and irregular
/// bills and savings, so moving money between lines lands in flexible.
@Suite struct BalancedFlexibleTests {
    let october = Month(year: 2026, month: 10)
    let brokerage = UUID()

    @Test func flexibleIsIncomeLessBillsAndSavings() {
        let plan = BudgetPlan(
            flexibleBudget: 1, roles: ["Rent": .fixed, "Charity": .irregular],
            expected: ["Rent": 2_000, "Charity": 100, "Interest": 999],  // an expected amount on income is ignored, as the sheet ignores it
            plannedIncome: ["Paychecks": 5_000], savings: [brokerage: 500])
        let balanced = FlexBudget.balanced(plan, kinds: [:])
        #expect(balanced.flexibleBudget == 2_400)
        #expect(FlexBudget.sheet(october, transactions: [], kinds: [:], plan: balanced).leftToBudget == 0)
    }

    @Test func pastIncomeFlexibleIsZeroAndTheGapShows() {
        let plan = BudgetPlan(flexibleBudget: 800, roles: ["Rent": .fixed], expected: ["Rent": 2_000], plannedIncome: ["Paychecks": 1_500])
        let balanced = FlexBudget.balanced(plan, kinds: [:])
        #expect(balanced.flexibleBudget == 0)
        #expect(FlexBudget.sheet(october, transactions: [], kinds: [:], plan: balanced).leftToBudget == -500)
    }

    @Test func withoutPlannedIncomeTheFlexibleBudgetHeSetStands() {
        #expect(FlexBudget.balanced(BudgetPlan(flexibleBudget: 1_800), kinds: [:]).flexibleBudget == 1_800)
    }
}
