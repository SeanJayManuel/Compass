import Core
import Foundation
import Testing

@Suite struct WeeklyReviewTests {
    /// Tuesday, Oct 20 2026; the week runs Sunday Oct 18 to Saturday Oct 24.
    let today = Day(year: 2026, month: 10, day: 20)
    var week: Week { Week(today) }
    let account = UUID()

    @Test func habitsShowThisWeeksCount() {
        let gym = Habit(
            title: "Gym", perWeek: 4, startedOn: Day(year: 2026, month: 9, day: 1),
            checkIns: [oct(16), oct(19), oct(20)])
        let review = review(habits: [gym])
        #expect(review.habits == [HabitWeek(habitID: gym.id, title: "Gym", done: 2, perWeek: 4, result: .inProgress(done: 2))])
    }

    @Test func reflectionsAndGoalsDoneAreTheOnesFromThisWeek() {
        let dates = LifeGoal(
            title: "5 dates", period: .quarter(Quarter(today)), progress: .count(current: 2, target: 5),
            entries: [LifeEntry(day: oct(12), note: "Too early"), LifeEntry(day: oct(19), note: "Went well")])
        let read = LifeGoal(
            title: "Read a book", period: .quarter(Quarter(today)), progress: .checkbox(done: true),
            status: .done(on: oct(20)))
        let older = LifeGoal(
            title: "Old", period: .quarter(Quarter(today)), progress: .checkbox(done: true),
            status: .done(on: oct(2)))
        let review = review(goals: [dates, read, older])
        #expect(review.reflections == [Reflection(goalTitle: "5 dates", entry: LifeEntry(day: oct(19), note: "Went well"))])
        #expect(review.goalsDone.map(\.title) == ["Read a book"])
    }

    @Test func flexibleSpendingIsComparedWithAWeeksShareOfTheBudget() {
        let spending = [
            tx(-120, "Groceries", oct(19)), tx(-1500, "Rent", oct(19)), tx(-40, "Restaurants", oct(17)), tx(2000, "Paychecks", oct(20))
        ]
        let review = review(transactions: spending, plan: BudgetPlan(flexibleBudget: 1300))
        #expect(review.flexibleSpent == 120)
        #expect(review.weeklyBudget == 300)
        #expect(!review.isOverBudget)
    }

    @Test func aWeekLateInAMonthThatsNearlySpentGetsOnlyWhatsLeft() {
        // Wednesday Oct 21: $1,717 of October's $1,800 went before this week and
        // $6 this week, leaving $77 for the 11 days left (the budget sheet's numbers).
        let wednesday = oct(21)
        let spending = [tx(-1717, "Groceries", oct(9)), tx(-6, "Coffee Shops", oct(20))]
        let review = WeeklyReview.make(
            week: Week(wednesday), today: wednesday, habits: [], goals: [], transactions: spending,
            kinds: [:], plan: BudgetPlan(flexibleBudget: 1800))
        // $83 left when the week began, over the 14 days from Sunday: $41.50 for its 7 days.
        #expect(review.weeklyBudget == Decimal(string: "41.5")!)
        #expect(review.monthLeft == 77)
        #expect(review.month == Month(year: 2026, month: 10))
        #expect(!review.isOverBudget)
    }

    @Test func spendingInAMonthAlreadyUsedUpIsOver() {
        let spent = [tx(-1900, "Groceries", oct(9))]
        let quiet = review(transactions: spent, plan: BudgetPlan(flexibleBudget: 1800))
        #expect(quiet.weeklyBudget == 0)
        #expect(quiet.monthLeft == -100)
        #expect(!quiet.isOverBudget)
        let coffee = review(transactions: spent + [tx(-5, "Coffee Shops", oct(20))], plan: BudgetPlan(flexibleBudget: 1800))
        #expect(coffee.isOverBudget)
    }

    @Test func aWeekAcrossTwoMonthsTakesEachMonthsShareOfItsDays() {
        // Sunday Sep 27 to Saturday Oct 3: $50 of September is left for its last
        // 4 days, and October's 3 days get 3/31 of a fresh $3,000.
        let spending = [tx(-2950, "Groceries", Day(year: 2026, month: 9, day: 10))]
        let review = WeeklyReview.make(
            week: Week(Day(year: 2026, month: 9, day: 28)), today: today, habits: [], goals: [],
            transactions: spending, kinds: [:], plan: BudgetPlan(flexibleBudget: 3000))
        #expect(review.weeklyBudget > Decimal(string: "340.32")! && review.weeklyBudget < Decimal(string: "340.33")!)
        #expect(review.month == Month(year: 2026, month: 10))
        #expect(review.monthLeft == 3000)
    }

    private func review(
        habits: [Habit] = [], goals: [LifeGoal] = [], transactions: [Transaction] = [],
        plan: BudgetPlan = BudgetPlan(flexibleBudget: 0)
    ) -> WeekReview {
        WeeklyReview.make(
            week: week, today: today, habits: habits, goals: goals, transactions: transactions,
            kinds: [:], plan: plan)
    }

    private func tx(_ amount: Decimal, _ category: String, _ day: Day) -> Transaction {
        Transaction(
            accountID: account, day: day, amount: amount, merchant: category, category: category,
            externalID: UUID().uuidString)
    }

    private func oct(_ day: Int) -> Day { Day(year: 2026, month: 10, day: day) }
}
