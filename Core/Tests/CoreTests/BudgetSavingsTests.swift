import Core
import Foundation
import Testing

@Suite struct BudgetSavingsTests {
    let october = Month(year: 2026, month: 10)
    let checking = Account(name: "Checking", accountClass: .cash, source: .simplefin)
    let savings = Account(name: "Vacation fund", accountClass: .cash, source: .simplefin)
    let brokerage = Account(name: "Brokerage", accountClass: .taxable, source: .simplefin)
    let roth = Account(name: "Roth IRA", accountClass: .retirement, source: .simplefin)
    let card = Account(name: "Card", accountClass: .debt, source: .simplefin)

    /// Money out of `from` and the same amount into `to`, filed or not.
    func move(_ amount: Decimal, from: Account, to: Account, day: Int = 5, category: String? = "Transfer") -> [Transaction] {
        [
            Transaction(
                accountID: from.id, day: Day(year: 2026, month: 10, day: day), amount: -amount,
                merchant: "Transfer to \(to.name)", category: category, externalID: UUID().uuidString),
            Transaction(
                accountID: to.id, day: Day(year: 2026, month: 10, day: day), amount: amount,
                merchant: "Transfer from \(from.name)", category: category, externalID: UUID().uuidString)
        ]
    }

    func sheet(_ transactions: [Transaction], plan: BudgetPlan) -> BudgetSheet {
        FlexBudget.sheet(october, transactions: transactions, kinds: [:], plan: plan)
    }

    @Test func savingIsMoneyMovedFromCheckingIntoAnAccountItsPlannedFor() {
        let plan = BudgetPlan(flexibleBudget: 1000, savings: [brokerage.id: 500, roth.id: 250, savings.id: 200])
        let sheet = sheet(
            move(500, from: checking, to: brokerage) + move(250, from: checking, to: roth)
                + move(60, from: checking, to: roth, day: 28, category: nil)  // not filed yet: still spending, not saving
                + move(100, from: brokerage, to: checking, day: 20)  // taken back out
                + move(1200, from: checking, to: card)  // a card payment isn't saving
                + move(300, from: brokerage, to: roth, day: 12)  // between two savings, not new saving
                + move(200, from: checking, to: savings, day: 2), plan: plan)

        #expect(
            sheet.savings.lines.sorted { $0.category < $1.category }
                == [
                    BudgetLine(category: brokerage.id.uuidString, planned: 500, actual: 400),
                    BudgetLine(category: roth.id.uuidString, planned: 250, actual: 250),
                    BudgetLine(category: savings.id.uuidString, planned: 200, actual: 200)
                ].sorted { $0.category < $1.category })
        #expect(sheet.savings.actual == 850)
    }

    @Test func plannedSavingsAreAJobForIncomeButNotAnExpense() {
        let plan = BudgetPlan(
            flexibleBudget: 2000, expected: ["Rent": 2100], plannedIncome: ["Paychecks": 5500],
            savings: [brokerage.id: 750])
        let sheet = sheet(
            [
                Transaction(
                    accountID: checking.id, day: Day(year: 2026, month: 10, day: 1), amount: 5500,
                    merchant: "Payroll", category: "Paychecks", externalID: "pay")
            ]
                + move(750, from: checking, to: brokerage), plan: plan)

        #expect(sheet.leftToBudget == 650)
        #expect(FlexBudget.balanced(plan, kinds: [:]).flexibleBudget == 2650)
        #expect(sheet.plannedExpenses == 4100)
        #expect(sheet.actualExpenses == 0)
        #expect(sheet.income.actual == 5500)
        #expect(sheet.savings.actual == 750)
        #expect(sheet.actualNet == 4750)
    }

    @Test func onlyAccountsHeAddedAreSavings() {
        // They save into the brokerage, not the Roth: a deposit to the Roth
        // isn't counted, and from the Roth to the brokerage is new saving.
        let sheet = sheet(
            move(400, from: checking, to: roth) + move(150, from: roth, to: brokerage),
            plan: BudgetPlan(flexibleBudget: 1000, savings: [brokerage.id: 500]))

        #expect(sheet.savings.lines == [BudgetLine(category: brokerage.id.uuidString, planned: 500, actual: 150)])
        #expect(sheet.savings.unbudgeted.isEmpty)
    }
}
