import Core
import Foundation
import Testing

/// Seam 43: a transaction split into categories, counted part by part.
@Suite struct SplitsTests {
    let oct = Day(year: 2026, month: 10, day: 12)
    let kinds: [String: CategoryKind] = [:]

    func target(_ amount: Decimal = -100, category: String? = "Shopping") -> Transaction {
        Transaction(
            accountID: UUID(), day: oct, amount: amount, merchant: "Target", statement: "TARGET 0412", category: category,
            externalID: UUID().uuidString)
    }

    func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let refusal as ClaudeRefusal { return refusal.message } catch { return "\(error)" }
    }

    @Test func aSplitTakesItsLargestPartsCategory() throws {
        let split = try Splits.split(target(), into: [("Groceries", 40), ("Household", 60)], kinds: kinds)
        #expect(split.splits == [TransactionSplit(category: "Groceries", amount: -40), TransactionSplit(category: "Household", amount: -60)])
        #expect(split.category == "Household" && split.amount == -100)
        // A refund splits the same way, money in.
        #expect(try Splits.split(target(30), into: [("Groceries", 10), ("Household", 20)], kinds: kinds).splits.map(\.amount) == [10, 20])
        // No parts takes the split off, keeping its category.
        #expect(try Splits.split(split, into: [], kinds: kinds).splits.isEmpty)
    }

    @Test func aSplitIsRefusedUnlessItsPartsAddUp() {
        let charge = target()
        #expect(refusal { _ = try Splits.split(charge, into: [("Groceries", 100)], kinds: kinds) }?.contains("two") == true)
        #expect(refusal { _ = try Splits.split(charge, into: [("Groceries", 40), ("Household", 50)], kinds: kinds) }?.contains("100") == true)
        #expect(refusal { _ = try Splits.split(charge, into: [("Groceries", 0), ("Household", 100)], kinds: kinds) } != nil)
        #expect(refusal { _ = try Splits.split(charge, into: [("Groceries", -40), ("Household", 140)], kinds: kinds) } != nil)
        #expect(refusal { _ = try Splits.split(charge, into: [("Groceries", 40), ("groceries", 60)], kinds: kinds) } != nil)
        #expect(refusal { _ = try Splits.split(charge, into: [("Groceries", 40), ("Transfer", 60)], kinds: kinds) }?.contains("spending") == true)
        #expect(refusal { _ = try Splits.split(target(2_000, category: "Paychecks"), into: [("Groceries", 1_000), ("Household", 1_000)], kinds: kinds) } != nil)
        var owed = charge
        owed.reimbursable = true
        #expect(refusal { _ = try Splits.split(owed, into: [("Groceries", 40), ("Household", 60)], kinds: kinds) }?.contains("owed") == true)
    }

    @Test func spendingCountsEachPartInItsCategory() throws {
        let split = try Splits.split(target(), into: [("Groceries", 40), ("Household", 60)], kinds: kinds)
        let month = Month(oct)
        let spend = Dictionary(uniqueKeysWithValues: Spending.month(month, transactions: [split], kinds: kinds).map { ($0.category, $0.thisMonth) })
        #expect(spend == ["Groceries": 40, "Household": 60])
        let grid = Spending.monthlyByCategory(endingIn: month, transactions: [split], kinds: kinds)
        #expect(Set(grid.map(\.category)) == ["Groceries", "Household"])
        #expect(Spending.trend("Groceries", endingIn: month, transactions: [split], kinds: kinds).last?.total == 40)
        // The budget: a fixed part is a bill paid, the rest flexible.
        var plan = BudgetPlan(flexibleBudget: 500)
        plan.roles["Household"] = .fixed
        plan.expected["Household"] = 60
        let sheet = FlexBudget.sheet(month, transactions: [split], kinds: kinds, plan: plan)
        #expect(sheet.fixed.lines.first { $0.category == "Household" }?.actual == 60)
        #expect(sheet.flexible.lines.map(\.category) == ["Groceries"])
        #expect(FlexBudget.month(month, today: oct, transactions: [split], kinds: kinds, plan: plan).flexibleSpent == 40)
    }

    @Test func aDayAndASearchSeeTheParts() throws {
        var split = try Splits.split(target(), into: [("Groceries", 40), ("Household", 60)], kinds: kinds)
        split.splits[1].category = "Transfer"  // as if a kind changed since; a day counts only spending parts
        let day = TransactionSearch.byDay([split], kinds: kinds)[0]
        #expect(day.spent == 40 && day.transactions.count == 1)
        let groceries = TransactionQuery(category: .named("Groceries"))
        #expect(TransactionSearch.filter([split], groceries).count == 1)
        #expect(TransactionIndex([split]).filter(groceries).count == 1)
    }

    @Test func rulesDontLearnFromASplitNorRefileIt() throws {
        let split = try Splits.split(target(), into: [("Groceries", 40), ("Household", 60)], kinds: kinds)
        #expect(CategoryRules.learn(from: [split]).all.isEmpty)
        // A merchant rule's refile leaves a split alone: it was made on purpose.
        #expect(ClaudeRules.refile([split, target()], key: "target", to: "Groceries", transfers: []).count == 1)
    }

    @Test func aRenameReachesInsideSplitsAndAMergeFoldsParts() throws {
        let split = try Splits.split(target(), into: [("Groceries", 30), ("Household", 50), ("Pets", 20)], kinds: kinds)
        let renamed = Splits.renaming(split, "Pets", to: "Pet care")
        #expect(renamed.splits.map(\.category) == ["Groceries", "Household", "Pet care"] && renamed.category == "Household")
        // Merging Groceries into Household leaves two parts, the larger one first in category.
        let merged = Splits.renaming(split, "Groceries", to: "Household")
        #expect(merged.splits == [TransactionSplit(category: "Household", amount: -80), TransactionSplit(category: "Pets", amount: -20)])
        // Down to one part, it's no longer split.
        let two = try Splits.split(target(), into: [("Groceries", 40), ("Household", 60)], kinds: kinds)
        let one = Splits.renaming(two, "Groceries", to: "Household")
        #expect(one.splits.isEmpty && one.category == "Household")
        #expect(Splits.renaming(two, "Travel", to: "Trips") == two)
    }

    @Test func undoingAMergeUnfoldsSplitsItFolded() throws {
        let before = try Splits.split(target(), into: [("Groceries", 40), ("Household", 60)], kinds: kinds)
        let folded = Splits.renaming(before, "Groceries", to: "Household")
        let edits = [before.id: TransactionEdit(before)]
        #expect(
            ClaudeRules.unfold(edits, from: "Groceries", into: "Household", current: [before.id: TransactionEdit(folded)])
                == [before.id: TransactionEdit(before)])
        // Refiled since: left alone.
        var refiled = TransactionEdit(folded)
        refiled.category = "Shopping"
        #expect(ClaudeRules.unfold(edits, from: "Groceries", into: "Household", current: [before.id: refiled]).isEmpty)
    }

    @Test func refilingAWholeTransactionClearsItsSplit() throws {
        let split = try Splits.split(target(), into: [("Groceries", 40), ("Household", 60)], kinds: kinds)
        var edit = TransactionEdit(split)
        edit.category = "Shopping"
        #expect(edit.saving(over: TransactionEdit(split)).splits.isEmpty)
        // A note alone keeps it, and so does putting a split back (undo).
        var noted = TransactionEdit(split)
        noted.note = "Back to school"
        #expect(noted.saving(over: TransactionEdit(split)).splits.count == 2)
        #expect(TransactionEdit(split).saving(over: TransactionEdit(target())).splits.count == 2)
    }

    @Test func transactionsAndEditsSavedBeforeSplitsReadBack() throws {
        let old =
            #"{"id":"5A1F4E1C-6D5B-4C47-9E61-1B2D2B0C0A11","accountID":"5A1F4E1C-6D5B-4C47-9E61-1B2D2B0C0A12","day":{"ordinal":740000},"amount":-5,"merchant":"Deli","externalID":"x"}"#
        let decoded = try JSONDecoder().decode(Transaction.self, from: Data(old.utf8))
        #expect(decoded.splits.isEmpty)
        let edit = #"{"note":"","oneOff":false,"reimbursable":false}"#
        #expect(try JSONDecoder().decode(TransactionEdit.self, from: Data(edit.utf8)).splits.isEmpty)
        let split = try Splits.split(target(), into: [("Groceries", 40), ("Household", 60)], kinds: kinds)
        #expect(try JSONDecoder().decode(Transaction.self, from: JSONEncoder().encode(split)) == split)
    }
}
