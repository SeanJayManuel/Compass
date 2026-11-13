import Core
import Foundation
import Testing

@Suite struct CategoryRulesTests {
    let account = UUID()
    func txn(_ merchant: String, _ category: String?, day: Int = 1, amount: Decimal = -10) -> Transaction {
        Transaction(
            accountID: account, day: Day(year: 2026, month: 10, day: day), amount: amount,
            merchant: merchant, category: category, externalID: UUID().uuidString)
    }

    @Test func storeNumbersAndCaseDontSplitAMerchant() {
        #expect(Merchant.key("CHIPOTLE 0412") == Merchant.key("Chipotle"))
        #expect(Merchant.key("7-Eleven") == "7 eleven")
    }

    @Test func eachMerchantLearnsItsMostCommonCategory() {
        let rules = CategoryRules.learn(from: [
            txn("Chipotle", "Restaurants"), txn("CHIPOTLE 0412", "Restaurants"), txn("Chipotle", "Groceries"),
            txn("Whole Foods", "Groceries"), txn("Mystery", nil)
        ])
        #expect(rules.category(for: "CHIPOTLE #1234") == "Restaurants")
        #expect(rules.category(for: "Whole Foods") == "Groceries")
        #expect(rules.category(for: "Mystery") == nil)
    }

    @Test func aTieGoesToTheMostRecentFiling() {
        let rules = CategoryRules.learn(from: [txn("Target", "Groceries", day: 1), txn("Target", "Shopping", day: 9)])
        #expect(rules.category(for: "Target") == "Shopping")
    }

    @Test func filingATransactionSetsTheRuleForItsMerchant() {
        var rules = CategoryRules.learn(from: [txn("Target", "Groceries")])
        rules.file(merchant: "TARGET 00012", as: "Shopping")
        #expect(rules.category(for: "Target") == "Shopping")
    }

    @Test func applyingRulesFilesOnlyUncategorizedTransactions() {
        let rules = CategoryRules.learn(from: [txn("Chipotle", "Restaurants")])
        let filed = rules.apply(to: [txn("Chipotle", nil), txn("Chipotle", "Business"), txn("Unknown", nil)])
        #expect(filed.map(\.category) == ["Restaurants", "Business", nil])
    }

    /// Lunch at Costco and a Costco paycheck are the same merchant, but
    /// money in and money out each learn and follow a rule of their own.
    @Test func moneyInAndMoneyOutFromOneMerchantHaveSeparateRules() {
        let rules = CategoryRules.learn(from: [
            txn("Costco", "Eating Out", amount: -15), txn("COSTCO 0412", "Eating Out", amount: -12),
            txn("Costco Payroll", "Paychecks", amount: 2700), txn("Costco", "Paychecks", amount: 2700)
        ])
        #expect(rules.category(for: "Costco") == "Eating Out")
        #expect(rules.category(for: "Costco", incoming: true) == "Paychecks")
        let filed = rules.apply(to: [txn("Costco", nil, amount: -9), txn("Costco", nil, amount: 2700)])
        #expect(filed.map(\.category) == ["Eating Out", "Paychecks"])
    }

    @Test func spendingAtAMerchantNeverFilesMoneyFromIt() {
        let rules = CategoryRules.learn(from: [txn("Costco", "Eating Out", amount: -15)])
        #expect(rules.apply(to: [txn("Costco", nil, amount: 2700)]).map(\.category) == [nil])
    }

    /// A merchant filed some other way than by hand (a synced copy taking its
    /// Monarch twin's category) still files its next transaction.
    @Test func historyFillsMerchantsWithNoStoredRule() {
        let stored = CategoryRules([CategoryRules.key(merchant: "Target", incoming: false): "Shopping"])
        let history = [
            txn("Taco Bell via DoorDash", "Eating Out"), txn("Target", "Groceries"),
            txn("Venmo", "Transfer"), txn("Paycheck", "Paychecks", amount: 2700)
        ]
        let rules = stored.filling(from: history, skipping: ["Transfer"])
        #expect(rules.category(for: "TACO BELL VIA DOORDASH") == "Eating Out")
        #expect(rules.category(for: "Target") == "Shopping")
        #expect(rules.category(for: "Paycheck", incoming: true) == "Paychecks")
        // Moving money is about the occasion, not the merchant.
        #expect(rules.category(for: "Venmo") == nil)
    }

    @Test func filingMoneyInSetsOnlyTheMoneyInRule() {
        var rules = CategoryRules.learn(from: [txn("Costco", "Eating Out", amount: -15)])
        rules.file(merchant: "COSTCO PAYROLL", incoming: true, as: "Paychecks")
        #expect(rules.category(for: "Costco") == "Eating Out")
        #expect(rules.category(for: "Costco Payroll", incoming: true) == "Paychecks")
        #expect(CategoryRules.key(for: txn("Costco", nil, amount: 2700)) != CategoryRules.key(for: txn("Costco", nil)))
    }
}

/// Filing by hand under a typed name files under the category already in
/// use when only case or spacing differs, so the budget isn't split by a twin.
@Suite struct TypedCategoryNameTests {
    @Test func aTypedNameIsTrimmedWithSpacesCollapsed() {
        #expect(CategoryRules.tidy("  Home   Improvement ") == "Home Improvement")
        #expect(CategoryRules.tidy("Coffee\tShops") == "Coffee Shops")
        #expect(CategoryRules.tidy("   ") == "")
    }

    @Test func aNameDifferingOnlyInCaseOrSpacingIsTheOneInUse() {
        let inUse = ["Software", "Home Improvement", "Groceries"]
        #expect(CategoryRules.existing("software", among: inUse) == "Software")
        #expect(CategoryRules.existing(" SOFTWARE ", among: inUse) == "Software")
        #expect(CategoryRules.existing("home  improvement", among: inUse) == "Home Improvement")
        #expect(CategoryRules.existing("Home Improvements", among: inUse) == nil)
        #expect(CategoryRules.existing("HomeImprovement", among: inUse) == nil)
        #expect(CategoryRules.existing("", among: inUse) == nil)
    }

    @Test func anExactNameWinsThenTheFirstInOrder() {
        // Twins from before this check: the exact one, else always the same one.
        #expect(CategoryRules.existing("software", among: ["Software", "software", "SOFTWARE"]) == "software")
        #expect(CategoryRules.existing("Software", among: ["software", "SOFTWARE"]) == "SOFTWARE")
        #expect(CategoryRules.existing("Software", among: ["SOFTWARE", "software"]) == "SOFTWARE")
    }
}
