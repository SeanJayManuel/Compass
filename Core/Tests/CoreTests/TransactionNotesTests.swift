import Core
import Foundation
import Testing

/// A transaction's note, one-off and reimbursable flags (round 3: "exclude
/// the reimbursable amount from spending").
@Suite struct TransactionNotesTests {
    let account = UUID()
    let october = Month(year: 2026, month: 10)

    func txn(
        _ category: String?, _ amount: Decimal, note: String = "", oneOff: Bool = false,
        reimbursable: Bool = false, owed: Decimal? = nil, id: String = UUID().uuidString
    ) -> Transaction {
        var transaction = Transaction(
            accountID: account, day: Day(year: 2026, month: 10, day: 5), amount: amount,
            merchant: "M", category: category, externalID: id)
        transaction.note = note
        transaction.oneOff = oneOff
        transaction.reimbursable = reimbursable
        transaction.reimbursableAmount = owed
        return transaction
    }

    @Test func whatsOwedBackIsntSpending() {
        #expect(txn("Dining", -100, reimbursable: true).spendingAmount == 0)
        #expect(txn("Dining", -100, reimbursable: true, owed: 60).spendingAmount == -40)
        // Never more than the charge, and never on money in.
        #expect(txn("Dining", -100, reimbursable: true, owed: 250).owedBack == 100)
        #expect(txn("Refunds", 30, reimbursable: true).owedBack == 0)
        #expect(txn("Dining", -100).spendingAmount == -100)
    }

    @Test func spendingTheBudgetAndTheDayLeaveOutWhatsOwedBack() {
        let dinner = txn("Dining", -100, reimbursable: true, owed: 60)
        let categories = Spending.month(october, transactions: [dinner, txn("Dining", -20)], kinds: [:])
        #expect(categories.first { $0.category == "Dining" }?.thisMonth == 60)
        let sheet = FlexBudget.sheet(october, transactions: [dinner, txn("Dining", -20)], kinds: [:], plan: BudgetPlan(flexibleBudget: 500))
        #expect(sheet.flexible.actual == 60)
        #expect(TransactionSearch.byDay([dinner]).first?.spent == 40)
    }

    @Test func searchFindsNotesAndFlags() {
        let all = [
            txn("Dining", -100, note: "Team dinner, Sam owes me", reimbursable: true, id: "a"),
            txn("Travel", -900, note: "Flight home", oneOff: true, id: "b"), txn("Dining", -12, id: "c")
        ]
        func ids(_ query: TransactionQuery) -> [String] { TransactionSearch.filter(all, query).map(\.externalID).sorted() }
        #expect(ids(TransactionQuery(hasNote: true)) == ["a", "b"])
        #expect(ids(TransactionQuery(oneOff: true)) == ["b"])
        #expect(ids(TransactionQuery(reimbursable: true)) == ["a"])
        #expect(ids(TransactionQuery(noteText: "sam owes")) == ["a"])
        #expect(ids(TransactionQuery(oneOff: false)) == ["a", "c"])
    }

    /// Transactions saved before these fields read back without them.
    @Test func olderTransactionsReadBack() throws {
        let old =
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","accountID":"6F9619FF-8B86-D011-B42D-00C04FC964FE","day":{"ordinal":740000},"amount":-12,"merchant":"M","statement":"","externalID":"x"}"#
        let decoded = try JSONDecoder().decode(Transaction.self, from: Data(old.utf8))
        #expect(decoded.note.isEmpty && !decoded.oneOff && !decoded.reimbursable && decoded.reimbursableAmount == nil)
        let annotated = txn("Dining", -100, note: "Team dinner", oneOff: true, reimbursable: true, owed: 60)
        #expect(try JSONDecoder().decode(Transaction.self, from: JSONEncoder().encode(annotated)) == annotated)
    }

    /// What Claude may change on a transaction: its note, flags and category,
    /// with undo while nothing has changed since.
    @Test func claudeEditsATransactionsNoteFlagsAndCategory() throws {
        let dinner = txn("Dining", -100)
        var edit = TransactionEdit(dinner)
        edit.note = "  Team dinner  "
        edit.reimbursable = true
        edit.reimbursableAmount = 60
        let after = try ClaudeRules.editTransaction(dinner, to: edit)
        #expect(after.note == "Team dinner" && after.reimbursable && after.reimbursableAmount == 60)
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.editTransaction(dinner, to: TransactionEdit(dinner)) }
        var tooMuch = TransactionEdit(dinner)
        tooMuch.reimbursable = true
        tooMuch.reimbursableAmount = 150
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.editTransaction(dinner, to: tooMuch) }
        var moneyIn = TransactionEdit(txn("Paychecks", 2_000))
        moneyIn.reimbursable = true
        #expect(throws: ClaudeRefusal.self) { try ClaudeRules.editTransaction(txn("Paychecks", 2_000), to: moneyIn) }
        // Undo puts back what was there, unless they changed it since.
        #expect(
            ClaudeRules.restore(current: TransactionEdit(after), before: TransactionEdit(dinner), after: TransactionEdit(after))
                == TransactionEdit(dinner))
        var since = after
        since.note = "Changed by hand"
        #expect(ClaudeRules.restore(current: TransactionEdit(since), before: TransactionEdit(dinner), after: TransactionEdit(after)) == nil)
    }
}
