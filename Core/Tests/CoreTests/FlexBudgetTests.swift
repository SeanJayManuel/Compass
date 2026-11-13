import Core
import Foundation
import Testing

@Suite struct FlexBudgetTests {
    let account = UUID()
    let october = Month(year: 2026, month: 10)
    let today = Day(year: 2026, month: 10, day: 20)  // 20 of 31 days

    func txn(_ category: String?, _ amount: Decimal, month: Int = 10, day: Int) -> Transaction {
        Transaction(
            accountID: account, day: Day(year: 2026, month: month, day: day), amount: amount,
            merchant: "M", category: category, externalID: UUID().uuidString)
    }

    var plan: BudgetPlan {
        BudgetPlan(
            flexibleBudget: 2000, roles: ["Rent": .fixed, "Internet": .fixed],
            expected: ["Rent": 2100, "Internet": 70])
    }

    @Test func categoriesStartFixedOrFlexibleFromTheirNames() {
        #expect(BudgetRole.guess("Rent") == .fixed)
        #expect(BudgetRole.guess("Mortgage") == .fixed)
        #expect(BudgetRole.guess("Phone and Internet") == .fixed)
        #expect(BudgetRole.guess("Insurance") == .fixed)
        #expect(BudgetRole.guess("Subscriptions") == .fixed)
        #expect(BudgetRole.guess("Restaurants & Bars") == .flexible)
        #expect(BudgetRole.guess("Groceries") == .flexible)
    }

    @Test func flexibleSpendingCountsAgainstOneBudgetWithADailyPace() {
        let month = FlexBudget.month(
            october, today: today,
            transactions: [
                txn("Restaurants", -500, day: 3), txn("Groceries", -300, day: 12), txn("Groceries", 40, day: 13),
                txn("Rent", -2100, day: 1), txn("Paychecks", 5000, day: 15), txn("Transfer", -900, day: 16)
            ], kinds: ["Paychecks": .income, "Transfer": .transfer], plan: plan)

        #expect(month.flexibleSpent == 760)
        #expect(month.flexibleRemaining == 1240)
        // 12 days left including today: 1240 / 12
        #expect(month.daysLeft == 12)
        #expect(month.dailyAllowance == Decimal(1240) / 12)
        // 20 of 31 days gone: expected so far is 2000 x 20/31
        #expect(month.expectedSoFar == Decimal(2000) * 20 / 31)
        #expect(!month.isOverPace)
    }

    @Test func buyingStockIsNotFlexibleSpending() {
        // Monarch files stock purchases under categories like these; they move
        // money into their brokerage, they don't spend it.
        let month = FlexBudget.month(
            october, today: today,
            transactions: [
                txn("Buy", -1000, day: 2), txn("Investments", -500, day: 3), txn("Stock Purchase", -250, day: 4),
                txn("Groceries", -60, day: 5)
            ], kinds: [:], plan: plan)
        #expect(month.flexibleSpent == 60)
    }

    @Test func paymentsBetweenHisOwnAccountsStopCountingOnceTransfersAreFiled() {
        // SimpleFIN leaves these uncategorized. The checking side of a card
        // payment counted as flexible spending on top of the card purchases
        // it paid for; the money arriving on the card was ignored.
        let checking = UUID(), card = UUID(), savings = UUID()
        func on(_ account: UUID, _ amount: Decimal, day: Int) -> Transaction {
            Transaction(
                accountID: account, day: Day(year: 2026, month: 10, day: day), amount: amount, merchant: "M",
                externalID: UUID().uuidString)
        }
        var transactions = [
            on(card, -700, day: 2), on(checking, -700, day: 15), on(card, 700, day: 16),  // purchases, then the payment
            on(checking, -1000, day: 10), on(savings, 1000, day: 10)  // into savings
        ]
        #expect(FlexBudget.month(october, today: today, transactions: transactions, kinds: [:], plan: plan).flexibleSpent == 2400)

        let transfers = TransferMatch.toFile(in: transactions, kinds: [:])
        for index in transactions.indices where transfers.contains(transactions[index].id) {
            transactions[index].category = TransferMatch.category
        }
        #expect(FlexBudget.month(october, today: today, transactions: transactions, kinds: [:], plan: plan).flexibleSpent == 700)
    }

    @Test func aBillWhoseCategoryIsNoLongerSpendingLeavesTheBills() {
        // A starting budget made when Investments still counted as spending
        // kept a monthly auto-invest as a fixed bill. Now that it's a transfer
        // it would sit there unpaid all month.
        let saved = BudgetPlan(
            flexibleBudget: 2000, roles: ["Investments": .fixed, "Rent": .fixed],
            expected: ["Investments": 500, "Rent": 2100, "Credit Card Payment": 900])
        let month = FlexBudget.month(
            october, today: today,
            transactions: [
                txn("Investments", -500, day: 2), txn("Rent", -2100, day: 1)
            ], kinds: ["Credit Card Payment": .transfer], plan: saved)
        #expect(month.bills.map(\.category) == ["Rent"])
        #expect(month.fixedExpected == 2100)
    }

    /// Spending and the greeting say the same whole dollars a day: rounded
    /// down, so spending it every day never ends the month over.
    @Test func theDailyAllowanceInWholeDollarsRoundsDown() {
        let lateOctober = Day(year: 2026, month: 10, day: 30)  // 2 days left
        let halfway = FlexBudget.month(
            october, today: lateOctober, transactions: [txn("Travel", -1797, day: 5)],
            kinds: [:], plan: plan)
        // $203 over 2 days is $101.50: $101, where rounding to even says $102.
        #expect(halfway.dailyAllowance == Decimal(string: "101.5")!)
        #expect(halfway.wholeDollarsADay == 101)

        let underADollar = FlexBudget.month(
            october, today: lateOctober,
            transactions: [txn("Travel", Decimal(string: "-1999.10")!, day: 5)],
            kinds: [:], plan: plan)
        #expect(underADollar.wholeDollarsADay == 0)

        let over = FlexBudget.month(
            october, today: lateOctober, transactions: [txn("Travel", -2300, day: 5)],
            kinds: [:], plan: plan)
        #expect(over.wholeDollarsADay == 0)
    }

    @Test func overspendingIsOverPaceWithNothingLeftPerDay() {
        let month = FlexBudget.month(
            october, today: today, transactions: [txn("Travel", -2300, day: 5)],
            kinds: [:], plan: plan)
        #expect(month.flexibleRemaining == -300)
        #expect(month.isOverPace)
        #expect(month.dailyAllowance == 0)
        #expect(month.standing == .overBudget)
    }

    @Test func standingSeparatesFasterThanPaceFromOverBudget() {
        let fast = FlexBudget.month(
            october, today: today, transactions: [txn("Travel", -1900, day: 5)],
            kinds: [:], plan: plan)
        #expect(fast.standing == .fasterThanPace)
        let calm = FlexBudget.month(
            october, today: today, transactions: [txn("Travel", -10, day: 5)],
            kinds: [:], plan: plan)
        #expect(calm.standing == .withinPace)
    }

    @Test func fixedBillsArePaidOrDueWithTheirUsualDay() {
        let month = FlexBudget.month(
            october, today: today,
            transactions: [
                txn("Rent", -2100, day: 1),
                txn("Internet", -70, month: 9, day: 28)
            ], kinds: [:], plan: plan)

        #expect(
            month.bills == [
                BillStatus(category: "Internet", expected: 70, paid: 0, usualDay: 28),
                BillStatus(category: "Rent", expected: 2100, paid: 2100, usualDay: nil)
            ])
        #expect(month.bills.first?.isPaid == false)
        #expect(month.fixedPaid == 2100)
        #expect(month.fixedExpected == 2170)
    }

    @Test func aBillPaidTwiceCountsBothPayments() {
        let month = FlexBudget.month(
            october, today: today,
            transactions: [
                txn("Internet", -70, day: 2), txn("Internet", -70, day: 18)
            ], kinds: [:], plan: plan)
        #expect(month.bills.first { $0.category == "Internet" }?.paid == 140)
    }

    @Test func smallFlexibleCategoriesFoldIntoEverythingElse() {
        let month = FlexBudget.month(
            october, today: today,
            transactions: [
                txn("Restaurants", -400, day: 2), txn("Groceries", -300, day: 3), txn("Shopping", -200, day: 4),
                txn("Coffee", -12, day: 5), txn("Laundry", -8, day: 6), txn("Taxi", -15, day: 7)
            ], kinds: [:], plan: plan)
        #expect(month.flexibleLines.map(\.category) == ["Restaurants", "Groceries", "Shopping", FlexBudget.everythingElse])
        #expect(month.flexibleLines.last?.amount == 35)
        #expect(month.flexibleLines.last?.categoryCount == 3)
    }

    @Test func aPastMonthHasNoDaysLeft() {
        let month = FlexBudget.month(
            Month(year: 2026, month: 9), today: today, transactions: [txn("Groceries", -100, month: 9, day: 5)],
            kinds: [:], plan: plan)
        #expect(month.daysLeft == 0)
        #expect(month.expectedSoFar == 2000)
    }

    @Test func aSingleFoldedCategoryKeepsItsOwnName() {
        // Five categories over the 10% share: three shown, the fourth and fifth folded...
        let two = FlexBudget.month(
            october, today: today,
            transactions: [
                txn("A", -500, day: 2), txn("B", -400, day: 3), txn("C", -300, day: 4), txn("D", -200, day: 5)
            ], kinds: [:], plan: plan)
        // ...but with only one left over, it's named, not "Everything else".
        #expect(two.flexibleLines.map(\.category) == ["A", "B", "C", "D"])
    }

    func grid(_ rows: [(String, [Decimal])]) -> [CategoryMonths] {
        rows.map { name, totals in
            CategoryMonths(
                category: name,
                months: totals.enumerated().map {
                    MonthTotal(month: Month(year: 2026, month: 1).adding($0.offset), total: $0.element)
                })
        }
    }

    @Test func aCategorysUsualMonthIsTheAverageOfTheLastThreeRounded() {
        let rows = grid([("Internet", [0, 0, 65, 70, 76])])
        #expect(FlexBudget.usualMonth("Internet", in: rows) == 70)
        #expect(FlexBudget.usualMonth("Missing", in: rows) == nil)
    }

    @Test func theSuggestedFlexibleBudgetIsRecentFlexibleSpendingOnly() {
        let rows = grid([("Groceries", [300, 300, 300]), ("Restaurants", [100, 200, 300]), ("Rent", [2100, 2100, 2100])])
        // Rent guesses fixed; Restaurants is excluded as not spending.
        #expect(FlexBudget.suggestedFlexibleBudget(from: rows, plan: plan, excluding: ["Restaurants"]) == 300)
        #expect(FlexBudget.suggestedFlexibleBudget(from: rows, plan: plan, excluding: []) == 500)
    }

    // MARK: A starting budget from history

    @Test func aStartingBudgetComesFromTheLastSixMonths() {
        let rows = grid([
            ("Rent", [2100, 2100, 2100, 2100, 2100, 2100]),
            ("Gym", [50, 50, 52, 50, 50, 50]),  // steady: fixed, though the name doesn't say so
            ("Groceries", [300, 420, 350, 510, 280, 390]),  // varies: flexible
            ("Insurance", [0, 0, 900, 0, 0, 0]),  // a once-a-year payment: not a monthly bill
            ("Restaurants", [200, 100, 300, 250, 150, 200])
        ])
        let plan = FlexBudget.template(from: rows)
        #expect(plan.role(of: "Rent") == .fixed)
        #expect(plan.role(of: "Gym") == .fixed)
        #expect(plan.role(of: "Groceries") == .flexible)
        #expect(plan.role(of: "Insurance") == .flexible)
        #expect(plan.expected == ["Rent": 2100, "Gym": 50])
        // Flexible spending, last three months: (510+250+0) + (280+150+0) + (390+200+0) = 1780 → 593
        #expect(plan.flexibleBudget == 593)
    }

    @Test func aBillMissingOneMonthIsStillFixed() {
        let plan = FlexBudget.template(from: grid([("Phone", [80, 80, 0, 80, 80, 80])]))
        #expect(plan.role(of: "Phone") == .fixed)
        #expect(plan.expected["Phone"] == 80)
    }
}
