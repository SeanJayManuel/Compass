import Core
import Foundation
import Testing

@Suite struct CategoryGuessTests {
    let account = UUID()
    func txn(_ merchant: String, _ category: String? = nil, statement: String = "", amount: Decimal = -10) -> Transaction {
        Transaction(
            accountID: account, day: Day(year: 2026, month: 10, day: 1), amount: amount,
            merchant: merchant, statement: statement, category: category, externalID: UUID().uuidString)
    }

    let categories: Set<String> = ["Eating Out", "Groceries", "Gas", "Taxi & Ride Shares", "Shopping", "Paychecks"]

    func guess(_ transaction: Transaction, from history: [Transaction] = []) -> String? {
        CategoryGuess.category(for: transaction, rules: CategoryRules.learn(from: history), categories: categories)
    }

    @Test func theMerchantsOwnRuleComesFirst() {
        #expect(guess(txn("CHIPOTLE 0412"), from: [txn("Chipotle", "Eating Out")]) == "Eating Out")
    }

    @Test func aKnownMerchantInsideTheNameFilesIt() {
        #expect(guess(txn("Taco Bell via DoorDash"), from: [txn("Taco Bell", "Eating Out")]) == "Eating Out")
    }

    @Test func theLongestKnownMerchantInsideTheNameWins() {
        let history = [txn("Whole Foods Market", "Groceries"), txn("Market", "Shopping")]
        #expect(guess(txn("Whole Foods Market 1042 Austin"), from: history) == "Groceries")
    }

    /// "Target via Instacart" is a Target order, whatever Instacart is filed as.
    @Test func theMerchantBeforeViaComesFirst() {
        let history = [txn("Target", "Shopping"), txn("Instacart", "Groceries")]
        #expect(guess(txn("Target via Instacart"), from: history) == "Shopping")
        #expect(guess(txn("Aldi via Instacart"), from: history) == "Groceries")
    }

    @Test func aKnownMerchantInTheBankTextFilesIt() {
        let history = [txn("DoorDash", "Eating Out")]
        #expect(guess(txn("Sweetgreen Delivery", statement: "DD *DOORDASH SWEETGREEN"), from: history) == "Eating Out")
    }

    @Test func aShortNameNeverMatchesInsideAnotherWord() {
        let history = [txn("Bp", "Gas"), txn("Ca", "Shopping")]
        #expect(guess(txn("Bpm Studio"), from: history) == nil)
        #expect(guess(txn("Studio CA"), from: history) == nil)
    }

    @Test func commonMerchantWordsFileMoneyOutUnderCategoriesInUse() {
        #expect(guess(txn("Shell Oil 57442")) == "Gas")
        #expect(guess(txn("Uber Trip", statement: "UBER *TRIP HELP.UBER.COM")) == "Taxi & Ride Shares")
        #expect(guess(txn("Joe's Pizza")) == "Eating Out")
    }

    @Test func aWordListCategoryHeDoesntUseIsNeverGuessed() {
        #expect(CategoryGuess.category(for: txn("Shell Oil"), rules: CategoryRules(), categories: ["Shopping"]) == nil)
    }

    @Test func moneyInFollowsOnlyMoneyInRules() {
        let history = [txn("Costco", "Eating Out"), txn("Costco Payroll", "Paychecks", amount: 2700)]
        #expect(guess(txn("Costco", amount: 2700), from: history) == nil)
        #expect(guess(txn("Costco Payroll Inc", amount: 2700), from: history) == "Paychecks")
        // A refund from a pizza place isn't guessed as eating out from its name alone.
        #expect(guess(txn("Joe's Pizza", amount: 12)) == nil)
    }

    @Test func aMerchantWithNothingToGoOnIsLeftToChoose() {
        #expect(guess(txn("Corp Paid Features", statement: "X CORP. PAID FEATURES")) == nil)
    }

    @Test func anExplanationNamesTheMerchantsRuleAndKeepsTheCategory() {
        let transaction = txn("CHIPOTLE 0412")
        let rules = CategoryRules.learn(from: [txn("Chipotle", "Eating Out")])
        let match = CategoryGuess.explanation(for: transaction, rules: rules, categories: categories)
        #expect(match?.category == "Eating Out")
        #expect(match?.evidence == .merchantRule)
    }

    @Test func anExplanationIdentifiesTheLongestKnownMerchantBeforeVia() {
        let rules = CategoryRules.learn(from: [txn("Whole Foods Market", "Groceries"), txn("Market", "Shopping"), txn("Instacart", "Shopping")])
        let match = CategoryGuess.explanation(for: txn("Whole Foods Market via Instacart"), rules: rules, categories: categories)
        #expect(match?.category == "Groceries")
        #expect(match?.evidence == .knownMerchant(phrase: "whole foods market", inStatement: false))
    }

    @Test func anExplanationSaysWhenTheKnownMerchantIsInTheBankText() {
        let rules = CategoryRules.learn(from: [txn("DoorDash", "Eating Out")])
        let match = CategoryGuess.explanation(for: txn("Sweetgreen Delivery", statement: "DD *DOORDASH SWEETGREEN"), rules: rules, categories: categories)
        #expect(match?.evidence == .knownMerchant(phrase: "doordash", inStatement: true))
    }

    @Test func anExplanationNamesTheCommonWordButDoesNotGuessRefunds() {
        let match = CategoryGuess.explanation(for: txn("Joe's Pizza"), rules: CategoryRules(), categories: categories)
        #expect(match?.category == "Eating Out")
        #expect(match?.evidence == .commonWord("pizza"))
        #expect(CategoryGuess.explanation(for: txn("Joe's Pizza", amount: 12), rules: CategoryRules(), categories: categories) == nil)
    }
}
