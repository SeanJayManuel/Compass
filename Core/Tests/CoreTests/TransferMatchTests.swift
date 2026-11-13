import Core
import Foundation
import Testing

@Suite struct TransferMatchTests {
    let checking = UUID()
    let savings = UUID()
    let card = UUID()

    func txn(_ account: UUID, _ amount: Decimal, day: Int, category: String? = nil, id: String) -> Transaction {
        Transaction(
            accountID: account, day: Day(year: 2026, month: 10, day: day), amount: amount,
            merchant: "M \(id)", category: category, externalID: id)
    }

    func ids(_ pairs: [TransferPair], in transactions: [Transaction]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0.externalID) })
        return pairs.map { "\(byID[$0.outgoing]!)>\(byID[$0.incoming]!)" }.sorted()
    }

    @Test func moneyOutOfOneAccountAndTheSameAmountIntoAnotherIsATransfer() {
        let all = [txn(checking, -500, day: 3, id: "out"), txn(savings, 500, day: 4, id: "in")]
        #expect(ids(TransferMatch.pairs(in: all, kinds: [:]), in: all) == ["out>in"])
    }

    @Test func matchedPairsReadAsFiledTransfersSoTheyLeaveSpending() {
        let all = [
            txn(checking, -1240, day: 20, id: "autopay"), txn(card, 1240, day: 22, id: "thanks"),
            txn(checking, -5, day: 20, category: "Coffee Shops", id: "coffee"),
            txn(checking, -60, day: 21, id: "unpaired")
        ]
        let read = TransferMatch.asFiled(all, kinds: [:])
        #expect(read.map(\.category) == [TransferMatch.category, TransferMatch.category, "Coffee Shops", nil])
        // The pair is no longer spending; the unpaired charge still is.
        #expect(TransactionSearch.byDay(read).map(\.spent) == [0, 60, 5])
        // Nothing else about them changes.
        #expect(read.map(\.id) == all.map(\.id))
        #expect(read.map(\.amount) == all.map(\.amount))
    }

    @Test func theSameAccountIsNeverATransfer() {
        // A purchase and its refund.
        let all = [txn(card, -40, day: 3, id: "buy"), txn(card, 40, day: 4, id: "refund")]
        #expect(TransferMatch.pairs(in: all, kinds: [:]).isEmpty)
    }

    @Test func theBusinessDaysApartAreLimitedToThreeUnlessToldOtherwise() {
        // Monday Oct 5 to Friday Oct 9, 2026: four business days.
        let all = [txn(checking, -500, day: 5, id: "out"), txn(savings, 500, day: 9, id: "in")]
        #expect(TransferMatch.pairs(in: all, kinds: [:]).isEmpty)
        #expect(ids(TransferMatch.pairs(in: all, kinds: [:], within: 4), in: all) == ["out>in"])
        // The money can arrive before it leaves: Saturday Oct 3 to Tuesday Oct 6.
        let early = [txn(checking, -500, day: 6, id: "out"), txn(savings, 500, day: 3, id: "in")]
        #expect(ids(TransferMatch.pairs(in: early, kinds: [:]), in: early) == ["out>in"])
    }

    @Test func aWeekendInBetweenDoesNotCount() {
        // An ACH move out on Friday Oct 2 lands on Wednesday Oct 7: five
        // calendar days, but only three business days.
        let all = [txn(checking, -1000, day: 2, id: "out"), txn(savings, 1000, day: 7, id: "in")]
        #expect(ids(TransferMatch.pairs(in: all, kinds: [:]), in: all) == ["out>in"])
        // Thursday Oct 1 to Wednesday Oct 7 is four business days.
        let longer = [txn(checking, -1000, day: 1, id: "out"), txn(savings, 1000, day: 7, id: "in")]
        #expect(TransferMatch.pairs(in: longer, kinds: [:]).isEmpty)
    }

    @Test func businessDaysBetweenSkipSaturdaysAndSundays() {
        func days(_ from: Int, _ to: Int) -> Int {
            TransferMatch.businessDays(from: Day(year: 2026, month: 10, day: from), to: Day(year: 2026, month: 10, day: to))
        }
        #expect(days(5, 5) == 0)
        #expect(days(5, 6) == 1)  // Monday to Tuesday
        #expect(days(2, 5) == 1)  // Friday to Monday
        #expect(days(2, 7) == 3)  // Friday to Wednesday
        #expect(days(3, 4) == 0)  // Saturday to Sunday
        #expect(days(7, 2) == 3)  // either order
        #expect(days(1, 15) == 10)  // two full weeks
        // A pair three business days apart can span at most five calendar days.
        #expect(TransferMatch.maxCalendarDays(forBusinessDays: 3) == 5)
        #expect(TransferMatch.maxCalendarDays(forBusinessDays: 5) == 7)
    }

    @Test func amountsMustMatchToTheCent() {
        let close = [txn(checking, -500, day: 3, id: "out"), txn(savings, Decimal(string: "500.01")!, day: 3, id: "in")]
        #expect(TransferMatch.pairs(in: close, kinds: [:]).isEmpty)
        let sameValue = [
            txn(checking, Decimal(string: "-1500")!, day: 3, id: "out"),
            txn(card, Decimal(string: "1500.00")!, day: 3, id: "in")
        ]
        #expect(ids(TransferMatch.pairs(in: sameValue, kinds: [:]), in: sameValue) == ["out>in"])
    }

    @Test func eachTransactionPairsOnceTheClosestDaysFirst() {
        // Two payments out and one in: the in pairs with the one on its own
        // day, even though the other came first.
        let all = [
            txn(checking, -200, day: 1, id: "early"), txn(checking, -200, day: 3, id: "same day"),
            txn(savings, 200, day: 3, id: "in")
        ]
        #expect(ids(TransferMatch.pairs(in: all, kinds: [:]), in: all) == ["same day>in"])
        // Two of each pair up one to one.
        let two = all + [txn(savings, 200, day: 2, id: "in 2")]
        #expect(ids(TransferMatch.pairs(in: two, kinds: [:]), in: two) == ["early>in 2", "same day>in"])
    }

    @Test func onlyUncategorizedOrTransferKindTransactionsTakePart() {
        let all = [
            // A paycheck and dinner they paid back: filed, so left alone.
            txn(checking, -80, day: 3, category: "Restaurants", id: "dinner"), txn(savings, 80, day: 3, category: "Paychecks", id: "pay"),
            // Monarch called the card side a payment; the checking side is new.
            txn(checking, -900, day: 5, id: "payment"), txn(card, 900, day: 6, category: "Credit Card Payment", id: "received"),
            // A category they marked as a transfer by hand.
            txn(checking, -300, day: 8, category: "Moving money", id: "move"), txn(savings, 300, day: 8, id: "arrives")
        ]
        let pairs = TransferMatch.pairs(in: all, kinds: ["Moving money": .transfer, "Paychecks": .income])
        #expect(ids(pairs, in: all) == ["move>arrives", "payment>received"])
    }

    @Test func theUncategorizedSidesAreFiledAsTransfersAndFindingAgainFilesNothing() {
        var all = [
            txn(checking, -900, day: 5, id: "payment"), txn(card, 900, day: 6, category: "Credit Card Payment", id: "received"),
            txn(checking, -300, day: 8, id: "to savings"), txn(savings, 300, day: 9, id: "arrives"),
            txn(card, -40, day: 9, id: "lunch")
        ]
        let filed = TransferMatch.toFile(in: all, kinds: [:])
        #expect(Set(all.filter { filed.contains($0.id) }.map(\.externalID)) == ["payment", "to savings", "arrives"])

        all = all.map { transaction in
            var copy = transaction
            if filed.contains(copy.id) { copy.category = TransferMatch.category }
            return copy
        }
        #expect(CategoryKind.guess(TransferMatch.category) == .transfer)
        #expect(TransferMatch.toFile(in: all, kinds: [:]).isEmpty)
    }

    @Test func aSideAlreadyPairedIsNotTakenOverByANewerCharge() {
        // Both sides of a move to savings were filed as Transfer. Then a $500
        // Venmo on the card arrives, a day closer to the savings side: it's
        // spending, and must not be filed.
        let filed = [
            txn(checking, -500, day: 1, category: "Transfer", id: "to savings"),
            txn(savings, 500, day: 3, category: "Transfer", id: "arrives"),
            txn(card, -500, day: 4, id: "venmo")
        ]
        #expect(ids(TransferMatch.pairs(in: filed, kinds: [:]), in: filed) == ["to savings>arrives"])
        #expect(TransferMatch.toFile(in: filed, kinds: [:]).isEmpty)

        // The same with Monarch's own card payment pair, and a new savings
        // withdrawal of the same amount the next day.
        let monarch = [
            txn(checking, -900, day: 5, category: "Credit Card Payment", id: "payment"),
            txn(card, 900, day: 7, category: "Credit Card Payment", id: "received"),
            txn(savings, -900, day: 8, id: "withdrawal")
        ]
        #expect(TransferMatch.toFile(in: monarch, kinds: [:]).isEmpty)
    }

    @Test func aFiledSideWithoutItsPartnerCanStillPairWithAnUncategorizedOne() {
        // Monarch filed the card side as a payment; the checking side arrived
        // by sync, uncategorized. Nothing else filed is waiting for it.
        let all = [
            txn(checking, -900, day: 5, id: "payment"),
            txn(card, 900, day: 6, category: "Credit Card Payment", id: "received"),
            txn(card, -40, day: 6, category: "Transfer", id: "other")
        ]
        #expect(ids(TransferMatch.pairs(in: all, kinds: [:]), in: all) == ["payment>received"])
        #expect(Set(all.filter { TransferMatch.toFile(in: all, kinds: [:]).contains($0.id) }.map(\.externalID)) == ["payment"])
    }
}

/// Transfers to or from accounts Compass can't see: only one side arrives,
/// so they're suggested from the bank's wording for the owner to confirm.
@Suite struct OneSidedTransferTests {
    let checking = UUID()
    let savings = UUID()

    func txn(
        _ merchant: String, _ statement: String = "", _ amount: Decimal = -200, category: String? = nil,
        account: UUID? = nil, day: Int = 5
    ) -> Transaction {
        Transaction(
            accountID: account ?? checking, day: Day(year: 2026, month: 10, day: day), amount: amount,
            merchant: merchant, statement: statement, category: category, externalID: merchant + statement)
    }

    func suggested(_ all: [Transaction]) -> [String] {
        let ids = TransferMatch.likelyOneSided(in: all, kinds: [:])
        return all.filter { ids.contains($0.id) }.map(\.merchant)
    }

    @Test func bankTransferWordingIsSuggested() {
        let all = [
            txn("Online Transfer", "ONLINE TRANSFER TO SAV XXXX1234"), txn("Chase", "AUTOPAY 241015"),
            txn("Amex", "PAYMENT THANK YOU"), txn("Payroll", "ONLINE TRANSFER FROM CHK 9921", 800)
        ]
        #expect(suggested(all) == ["Online Transfer", "Chase", "Amex", "Payroll"])
    }

    @Test func ordinarySpendingIsNot() {
        let all = [
            txn("Transferwise", "TRANSFERWISE LTD"), txn("Zelle", "ZELLE PAYMENT TO JOHN"),
            txn("Venmo", "VENMO PAYMENT"), txn("Blue Cup Coffee", "BLUE CUP 0412")
        ]
        #expect(suggested(all).isEmpty)
    }

    @Test func filedOrAlreadyPairedTransactionsAreLeftAlone() {
        let filed = txn("Chase", "AUTOPAY", category: "Groceries")
        let out = txn("Online Transfer", "ONLINE TRANSFER TO SAV", -500)
        let into = txn("Online Transfer", "ONLINE TRANSFER FROM CHK", 500, account: savings, day: 6)
        #expect(suggested([filed, out, into]).isEmpty)
    }
}
