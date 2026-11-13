import Core
import Foundation
import Testing

/// Seam 44: spending a goal pays for, kept out of the budget, and the money
/// moved out of the goal's account to cover it.
@Suite struct GoalFundingTests {
    let nov3 = Day(year: 2026, month: 11, day: 3)
    let kinds: [String: CategoryKind] = [:]
    let card = Account(name: "Sapphire", accountClass: .debt, source: .manual)
    let checking = Account(name: "Checking", accountClass: .cash, source: .manual)
    let travelFund = Account(name: "Travel Fund", accountClass: .cash, source: .manual)
    let brokerage = Account(name: "Brokerage", accountClass: .taxable, source: .manual)

    let travel: Goal

    init() { travel = Goal(name: "$5K Travel Fund", kind: .accountTotal([travelFund.id]), target: 5_000) }
    var accounts: [Account] { [card, checking, travelFund, brokerage] }

    func flight(_ amount: Decimal = -400, day: Day? = nil, category: String? = "Travel") -> Transaction {
        Transaction(
            accountID: card.id, day: day ?? nov3, amount: amount, merchant: "Air Canada", category: category,
            externalID: UUID().uuidString)
    }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let refusal as ClaudeRefusal { return refusal.message } catch { return "\(error)" }
    }

    @Test func aChargePaidFromAGoalIsOutOfTheBudget() throws {
        let paid = try GoalFunding.pay(flight(), from: travel, amount: nil, accounts: accounts, kinds: kinds)
        #expect(paid.paidFromGoal == travel.id && paid.paidByGoal == 400 && paid.budgetAmount == 0)
        let lunch = Transaction(accountID: card.id, day: nov3, amount: -30, merchant: "Pai", category: "Restaurants", externalID: "l")
        let month = Month(nov3)
        let plan = BudgetPlan(flexibleBudget: 1_000)
        let sheet = FlexBudget.sheet(month, transactions: [paid, lunch], kinds: kinds, plan: plan)
        #expect(sheet.flexible.actual == 30 && sheet.actualExpenses == 30)
        // All of it paid by the goal leaves no $0 Travel line.
        #expect(sheet.flexible.lines.map(\.category) == ["Restaurants"])
        #expect(sheet.paidFromGoals == [travel.id: 400])
        #expect(FlexBudget.month(month, today: nov3, transactions: [paid, lunch], kinds: kinds, plan: plan).flexibleSpent == 30)
        // Spending still counts it: it's real Travel spending.
        #expect(Spending.month(month, transactions: [paid], kinds: kinds).first?.thisMonth == 400)
        // Part of it: $250 from the fund, $150 in the budget.
        let part = try GoalFunding.pay(flight(), from: travel, amount: 250, accounts: accounts, kinds: kinds)
        #expect(part.paidByGoal == 250 && part.budgetAmount == -150)
        #expect(FlexBudget.sheet(month, transactions: [part], kinds: kinds, plan: plan).flexible.actual == 150)
        // A day's spent leaves it out too, and says what goals paid.
        let day = TransactionSearch.byDay([paid, lunch], kinds: kinds)[0]
        #expect(day.spent == 30 && day.paidFromGoals == 400)
        // No goal takes it off.
        #expect(try GoalFunding.pay(paid, from: nil, amount: nil, accounts: accounts, kinds: kinds).paidByGoal == 0)
    }

    @Test func onlyACashGoalPaysAndOnlyForSpending() throws {
        func pay(_ transaction: Transaction, from goal: Goal, amount: Decimal? = nil) -> String? {
            refusal { _ = try GoalFunding.pay(transaction, from: goal, amount: amount, accounts: accounts, kinds: kinds) }
        }
        let netWorth = Goal(name: "$100K Networth", kind: .netWorth, target: 100_000)
        let invested = Goal(name: "$100K Invested", kind: .accountTotal([brokerage.id]), target: 100_000)
        let mixed = Goal(name: "Mixed", kind: .accountTotal([travelFund.id, brokerage.id]), target: 10_000)
        var retired = travel
        retired.status = .retired(reason: "Moved")
        for goal in [netWorth, invested, mixed, retired] { #expect(pay(flight(), from: goal)?.contains("cash") == true) }
        #expect(GoalFunding.canPay(travel, accounts: accounts))
        #expect(pay(flight(), from: travel, amount: 401)?.contains("400") == true)
        #expect(pay(flight(), from: travel, amount: 0) != nil)
        #expect(pay(flight(25), from: travel) != nil)
        #expect(pay(flight(category: "Transfer"), from: travel)?.contains("spending") == true)
        let split = try Splits.split(flight(), into: [("Travel", 300), ("Restaurants", 100)], kinds: kinds)
        #expect(pay(split, from: travel)?.contains("split") == true)
        // Owed back leaves less for the goal: $100 back, so $300 at most.
        var shared = flight()
        shared.reimbursable = true
        shared.reimbursableAmount = 100
        #expect(pay(shared, from: travel, amount: 301) != nil)
        #expect(try GoalFunding.pay(shared, from: travel, amount: nil, accounts: accounts, kinds: kinds).paidByGoal == 300)
        // A goal's charge isn't split, as an owed-back one isn't.
        let paid = try GoalFunding.pay(flight(), from: travel, amount: nil, accounts: accounts, kinds: kinds)
        #expect(refusal { _ = try Splits.split(paid, into: [("Travel", 300), ("Restaurants", 100)], kinds: kinds) }?.contains("goal") == true)
    }

    /// A move between two of their accounts, filed as transfers on both sides.
    func move(_ amount: Decimal, from: Account, to: Account, on day: Day) -> [Transaction] {
        [
            Transaction(
                accountID: from.id, day: day, amount: -amount, merchant: "Transfer to \(to.name)", category: "Transfer",
                externalID: UUID().uuidString),
            Transaction(
                accountID: to.id, day: day, amount: amount, merchant: "Transfer from \(from.name)", category: "Transfer",
                externalID: UUID().uuidString)
        ]
    }

    @Test func movingMoneyOutOfTheFundPaysWhatItOwes() throws {
        let paid = try GoalFunding.pay(flight(), from: travel, amount: nil, accounts: accounts, kinds: kinds)
        let saved = move(200, from: checking, to: travelFund, on: Day(year: 2026, month: 11, day: 1))
        let covered = move(600, from: travelFund, to: checking, on: Day(year: 2026, month: 11, day: 20))
        let transactions = [paid] + saved + covered
        let ledger = GoalFunding.ledger(goals: [travel], transactions: transactions, kinds: kinds)
        // Owed from the charge until the money's moved.
        #expect(ledger.toMove(travel.id, on: Day(year: 2026, month: 11, day: 2)) == 0)
        #expect(ledger.toMove(travel.id, on: Day(year: 2026, month: 11, day: 10)) == 400)
        #expect(ledger.toMove(travel.id, on: Day(year: 2026, month: 11, day: 20)) == 0)
        #expect(ledger.settling == [covered[0].id: 400])
        #expect(ledger.paid(by: travel.id).map(\.id) == [paid.id])

        // The budget's savings line: $200 in, $600 out of which $400 paid for the flight.
        var plan = BudgetPlan(flexibleBudget: 1_000)
        plan.savings[travelFund.id] = 200
        let month = Month(nov3)
        let sheet = FlexBudget.sheet(month, transactions: transactions, kinds: kinds, plan: plan, settling: ledger.settling)
        #expect(sheet.savings.lines.first?.actual == 0)
        #expect(sheet.actualNet == 0)
        // Without the goal paying, the flight is an expense and $400 of the move is saving taken back.
        let unpaid = FlexBudget.sheet(month, transactions: [flight()] + saved + covered, kinds: kinds, plan: plan)
        #expect(unpaid.savings.lines.first?.actual == -400 && unpaid.actualNet == 0)
        // The savings rate's money moved: $200 in, the $200 left over taken back out.
        let profile = PayProfile()
        #expect(SavingsRate.moved(transactions, kinds: kinds, into: [travelFund.id], profile: profile, settling: ledger.settling)[month] == 0)
        let justTheFlight = [paid] + saved + move(400, from: travelFund, to: checking, on: Day(year: 2026, month: 11, day: 20))
        let settled = GoalFunding.ledger(goals: [travel], transactions: justTheFlight, kinds: kinds).settling
        #expect(SavingsRate.moved(justTheFlight, kinds: kinds, into: [travelFund.id], profile: profile, settling: settled)[month] == 200)
    }

    @Test func aMoveJustBeforeTheChargeCountsButNotAnOldOne() throws {
        let paid = try GoalFunding.pay(flight(), from: travel, amount: nil, accounts: accounts, kinds: kinds)
        let early = move(400, from: travelFund, to: card, on: Day(year: 2026, month: 10, day: 25))
        let ledger = GoalFunding.ledger(goals: [travel], transactions: [paid] + early, kinds: kinds)
        #expect(ledger.toMove(travel.id, on: nov3) == 0 && ledger.settling == [early[0].id: 400])
        let old = move(400, from: travelFund, to: checking, on: Day(year: 2026, month: 9, day: 1))
        #expect(GoalFunding.ledger(goals: [travel], transactions: [paid] + old, kinds: kinds).toMove(travel.id, on: nov3) == 400)
        // Paid straight from the fund's own account: nothing to move.
        var direct = try GoalFunding.pay(flight(), from: travel, amount: nil, accounts: accounts, kinds: kinds)
        direct.accountID = travelFund.id
        #expect(GoalFunding.ledger(goals: [travel], transactions: [direct], kinds: kinds).toMove(travel.id, on: nov3) == 0)
    }

    @Test func theGoalShowsWhatsLeftAndPacesBySaving() throws {
        let aug1 = Day(year: 2026, month: 8, day: 1), nov1 = Day(year: 2026, month: 11, day: 1)
        let nov10 = Day(year: 2026, month: 11, day: 10), nov20 = Day(year: 2026, month: 11, day: 20)
        let today = Day(year: 2026, month: 11, day: 25)
        let paid = try GoalFunding.pay(flight(), from: travel, amount: nil, accounts: accounts, kinds: kinds)
        // The fund's balance: $2,600 until $400 moves out on Nov 20.
        let moved = [
            DailyTotal(day: aug1, total: 2_000), DailyTotal(day: nov1, total: 2_600),
            DailyTotal(day: nov10, total: 2_600), DailyTotal(day: nov20, total: 2_200)
        ]
        let covered = move(400, from: travelFund, to: checking, on: nov20)
        let ledger = GoalFunding.ledger(goals: [travel], transactions: [paid] + covered, kinds: kinds)
        let available = GoalFunding.available(moved, goal: travel.id, ledger: ledger)
        #expect(available.map(\.total) == [2_000, 2_600, 2_200, 2_200])
        // What they saved paces the goal, whatever the fund spent.
        let saving = [DailyTotal(day: aug1, total: 2_000), DailyTotal(day: nov1, total: 2_600), DailyTotal(day: nov20, total: 2_600)]
        let progress = GoalProgress.evaluate(travel, measured: available, today: today)
        #expect(progress.current == 2_200 && progress.fraction == Decimal(string: "0.44"))
        #expect(progress.pacePerMonth == GoalProgress.evaluate(travel, measured: saving, today: today).pacePerMonth)

        // Not moved yet: the balance is still $2,600, and $400 of it is spoken for.
        let unmoved = [DailyTotal(day: aug1, total: 2_000), DailyTotal(day: nov1, total: 2_600), DailyTotal(day: nov20, total: 2_600)]
        let owing = GoalFunding.ledger(goals: [travel], transactions: [paid], kinds: kinds)
        #expect(owing.toMove(travel.id, on: today) == 400)
        let stillOwed = GoalFunding.available(unmoved, goal: travel.id, ledger: owing)
        #expect(GoalProgress.evaluate(travel, measured: stillOwed, today: today).current == 2_200)
        // A goal that paid for nothing is as measured.
        #expect(GoalFunding.available(unmoved, goal: UUID(), ledger: owing) == unmoved)
    }
}
