import Core
import Foundation
import Testing

@Suite struct TransactionSearchTests {
    let account = UUID()
    var chipotle: Transaction { tx("CHIPOTLE 0412", day: 3, category: "Restaurants", id: "a") }
    var rent: Transaction { tx("Landlord", statement: "ACH RENT PAYMENT", day: 1, category: "Rent", id: "b") }
    var unfiled: Transaction { tx("Corner Store", day: 5, category: nil, id: "c") }
    var september: Transaction { tx("Chipotle", day: 28, month: 9, category: "Restaurants", id: "d") }
    var all: [Transaction] { [chipotle, rent, unfiled, september] }

    @Test func anEmptyQueryShowsEverythingNewestFirst() {
        #expect(TransactionSearch.filter(all, TransactionQuery()).map(\.externalID) == ["c", "a", "b", "d"])
    }

    @Test func textIgnoresCaseAndStoreNumbers() {
        #expect(TransactionSearch.filter(all, TransactionQuery(text: "chipotle")).map(\.externalID) == ["a", "d"])
    }

    @Test func textAlsoMatchesTheStatement() {
        #expect(TransactionSearch.filter(all, TransactionQuery(text: "rent payment")).map(\.externalID) == ["b"])
    }

    @Test func filtersByCategoryOrUnfiled() {
        #expect(TransactionSearch.filter(all, TransactionQuery(category: .named("Restaurants"))).map(\.externalID) == ["a", "d"])
        #expect(TransactionSearch.filter(all, TransactionQuery(category: .unfiled)).map(\.externalID) == ["c"])
    }

    @Test func filtersByMonthAndCombines() {
        let query = TransactionQuery(text: "chipotle", month: Month(year: 2026, month: 10))
        #expect(TransactionSearch.filter(all, query).map(\.externalID) == ["a"])
    }

    @Test func transactionsGroupByDayNewestFirstWithEachDaysNet() {
        let days = TransactionSearch.byDay([
            tx("Coffee", day: 3, category: nil, id: "a", amount: Decimal(string: "-4.50")!),
            tx("Payroll", day: 5, category: "Paychecks", id: "b", amount: 2500),
            tx("Lunch", day: 5, category: "Restaurants", id: "c", amount: -18),
            tx("Refund", day: 3, category: "Shopping", id: "d", amount: 20)
        ])
        #expect(days.map(\.day) == [Day(year: 2026, month: 10, day: 5), Day(year: 2026, month: 10, day: 3)])
        // Credits count up, debits down.
        #expect(days.map(\.net) == [2482, Decimal(string: "15.50")!])
        #expect(days.map { $0.transactions.map(\.externalID) } == [["c", "b"], ["d", "a"]])
        #expect(TransactionSearch.byDay([]).isEmpty)
    }

    @Test func aDayHeaderCountsSpendingNotCardPayments() {
        // Paying the card isn't spending: the Laundry charge is.
        let days = TransactionSearch.byDay([
            tx("Chase", day: 21, category: "Credit Card Payment", id: "a", amount: -2_160),
            tx("Laundry", day: 21, category: "Laundry", id: "b", amount: Decimal(string: "-5.89")!)
        ])
        #expect(days.map(\.spent) == [Decimal(string: "5.89")!])
        #expect(days.map(\.received) == [0])
        // The net still counts everything.
        #expect(days.map(\.net) == [Decimal(string: "-2165.89")!])
    }

    @Test func aDayHeaderCountsIncomeAsReceivedAndLeavesTransfersOut() {
        let days = TransactionSearch.byDay([
            tx("Employer", day: 15, category: "Paychecks", id: "a", amount: 2_600),
            tx("To Savings", day: 15, category: "Transfer", id: "b", amount: -500),
            tx("Snack", day: 15, category: "Restaurants", id: "c", amount: Decimal(string: "-8.33")!)
        ])
        #expect(days.map(\.spent) == [Decimal(string: "8.33")!])
        #expect(days.map(\.received) == [2_600])
        #expect(days.map(\.net) == [Decimal(string: "2091.67")!])
    }

    @Test func aDayHeaderUsesTheKindsHeHasSet() {
        // "Side Gig" is income only because they said so, and "Fees" is a transfer for the same reason.
        let kinds: [String: CategoryKind] = ["Side Gig": .income, "Fees": .transfer]
        let days = TransactionSearch.byDay(
            [
                tx("Client", day: 4, category: "Side Gig", id: "a", amount: 300),
                tx("Bank", day: 4, category: "Fees", id: "b", amount: -12)
            ], kinds: kinds)
        #expect(days.map(\.received) == [300])
        #expect(days.map(\.spent) == [0])
    }

    @Test func anUnfiledChargeIsSpendingButAnUnfiledCreditIsNotIncome() {
        let days = TransactionSearch.byDay([
            tx("Corner Store", day: 6, category: nil, id: "a", amount: -20),
            tx("Mystery deposit", day: 7, category: nil, id: "b", amount: 50)
        ])
        #expect(days.map(\.day.ordinal) == [Day(year: 2026, month: 10, day: 7).ordinal, Day(year: 2026, month: 10, day: 6).ordinal])
        #expect(days.map(\.received) == [0, 0])
        #expect(days.map(\.spent) == [0, 20])
        #expect(days.map(\.net) == [50, -20])
        // Neither day is a transfer day: a deposit nobody has filed isn't a transfer.
        #expect(days.map(\.transfersOnly) == [false, false])
    }

    @Test func anUnfiledCardPaymentMatchedAsATransferIsNotSpent() {
        // The autopay out of checking and the card's "Payment thank you" pair up
        // (TransferMatch), but neither is filed yet.
        let autopay = tx("Rewards Card Autopay", day: 20, category: nil, id: "a", amount: -1240)
        let ride = tx("Rideshare", day: 20, category: "Taxi", id: "b", amount: Decimal(string: "-26.25")!)
        let payment = Transaction(
            accountID: UUID(), day: Day(year: 2026, month: 10, day: 22), amount: 1240,
            merchant: "Payment Thank You", category: nil, externalID: "c")
        let days = TransactionSearch.byDay([autopay, ride], transfers: [autopay.id, payment.id])
        #expect(days.map(\.spent) == [Decimal(string: "26.25")!])

        // A day of nothing but a matched, unfiled transfer is transfers only.
        let alone = TransactionSearch.byDay([payment], transfers: [autopay.id, payment.id])
        #expect(alone.map(\.spent) == [0])
        #expect(alone.map(\.received) == [0])
        #expect(alone.map(\.transfersOnly) == [true])
    }

    @Test func aDayIsTransfersOnlyWhenEveryTransactionOnItIsATransfer() {
        // "Fees" is a transfer only because they said so.
        let kinds: [String: CategoryKind] = ["Fees": .transfer]
        let days = TransactionSearch.byDay(
            [
                // The 1st: a card payment and a transfer out.
                tx("Card Payment", day: 1, category: "Credit Card Payment", id: "a", amount: -800),
                tx("To Savings", day: 1, category: "Transfer", id: "b", amount: -500),
                // The 2nd: a transfer, but also a deposit nobody has filed.
                tx("To Savings", day: 2, category: "Transfer", id: "c", amount: -500),
                tx("Mystery deposit", day: 2, category: nil, id: "d", amount: 50),
                // The 3rd: only an unfiled deposit.
                tx("Mystery deposit", day: 3, category: nil, id: "e", amount: 50),
                // The 4th: only a paycheck taken back, which is income-kind, not a transfer.
                tx("Employer", day: 4, category: "Paychecks", id: "f", amount: -100),
                // The 5th: a charge and its refund cancel out to nothing spent.
                tx("Shop", day: 5, category: "Shopping", id: "g", amount: -30),
                tx("Shop", day: 5, category: "Shopping", id: "h", amount: 30),
                // The 6th: a transfer under a category they set the kind of.
                tx("Bank", day: 6, category: "Fees", id: "i", amount: -12)
            ], kinds: kinds)
        // Newest first: the 6th back to the 1st.
        #expect(days.map(\.day.ordinal) == (1...6).reversed().map { Day(year: 2026, month: 10, day: $0).ordinal })
        #expect(days.map(\.transfersOnly) == [true, false, false, false, false, true])
        // The days that aren't transfers-only still spent and received what the header says.
        #expect(days.map(\.spent) == [0, 0, 0, 0, 0, 0])
        #expect(days.map(\.received) == [0, 0, -100, 0, 0, 0])
    }

    @Test func refundsTakeOffSpendingAndCanOutweighTheCharges() {
        let days = TransactionSearch.byDay([
            tx("Shop", day: 9, category: "Shopping", id: "a", amount: -30),
            tx("Shop", day: 9, category: "Shopping", id: "b", amount: 12),
            tx("Return", day: 10, category: "Shopping", id: "c", amount: 45),
            tx("Snack", day: 10, category: "Restaurants", id: "d", amount: -10)
        ])
        // Newest first: the 10th, then the 9th.
        #expect(days.map(\.spent) == [-35, 18])
        #expect(days.map(\.received) == [0, 0])
        #expect(days.map(\.net) == [35, -18])
    }

    @Test func aPageEndsAtTheEndOfADay() {
        // Newest first: the 5th has two, the 3rd two, the 1st one.
        let list = TransactionSearch.filter(
            [
                tx("A", day: 5, category: nil, id: "e"), tx("B", day: 5, category: nil, id: "d"),
                tx("C", day: 3, category: nil, id: "c"), tx("D", day: 3, category: nil, id: "b"),
                tx("E", day: 1, category: nil, id: "a")
            ], TransactionQuery())
        // Three would cut the 3rd in half, so the page takes all of it, and
        // each day's net is the whole day's.
        #expect(TransactionSearch.page(list, count: 3).map(\.externalID) == ["e", "d", "c", "b"])
        #expect(TransactionSearch.page(list, count: 2).map(\.externalID) == ["e", "d"])
        #expect(TransactionSearch.page(list, count: 9).count == 5)
        #expect(TransactionSearch.page(list, count: 0).isEmpty)
        #expect(TransactionSearch.page([], count: 3).isEmpty)
    }

    @Test func aFreshPageGoesOnTopOfAnOlderHistoryFromTheDayItEnds() {
        // The history as last read, newest first: the 5th, 3rd and 1st.
        let older = [
            tx("A", day: 5, category: nil, id: "e"), tx("C", day: 3, category: "Old", id: "c"),
            tx("D", day: 3, category: nil, id: "b"), tx("E", day: 1, category: nil, id: "a")
        ]
        // Read since: a new charge on the 6th, and the 3rd refiled.
        let page = [
            tx("F", day: 6, category: nil, id: "f"), tx("A", day: 5, category: nil, id: "e"),
            tx("C", day: 3, category: "New", id: "c"), tx("D", day: 3, category: nil, id: "b")
        ]
        let spliced = TransactionSearch.splice(page, onto: older)
        #expect(spliced.map(\.externalID) == ["f", "e", "c", "b", "a"])
        #expect(spliced[2].category == "New")
        #expect(TransactionSearch.splice([], onto: older).map(\.externalID) == ["e", "c", "b", "a"])
    }

    @Test func theIndexFindsWhatTheFilterFinds() {
        // Built once for a long history: sorted and keyed up front, so each
        // search is a scan.
        let index = TransactionIndex(all)
        let queries = [
            TransactionQuery(), TransactionQuery(text: "chipotle"), TransactionQuery(text: "rent payment"),
            TransactionQuery(text: "CHIPOTLE #0412"), TransactionQuery(text: "nothing like it"),
            TransactionQuery(category: .named("Restaurants")), TransactionQuery(category: .unfiled),
            TransactionQuery(text: "chipotle", month: Month(year: 2026, month: 10))
        ]
        for query in queries {
            #expect(index.filter(query).map(\.externalID) == TransactionSearch.filter(all, query).map(\.externalID), "\(query)")
        }
        #expect(index.count == 4)
        #expect(index.newest(2).map(\.externalID) == ["c", "a"])
    }

    @Test func theIndexListsItsMonthsNewestFirstAndItsCategories() {
        let index = TransactionIndex(all)
        #expect(index.months == [Month(year: 2026, month: 10), Month(year: 2026, month: 9)])
        #expect(index.categories == ["Restaurants", "Rent"])
        #expect(TransactionIndex([]).months.isEmpty)
    }

    @Test func summaryCountsMatchingIncomeAndSpendingButNotTransfers() {
        let paired = tx("Card autopay", day: 3, category: nil, id: "pair", amount: -500)
        let summary = TransactionSearch.summary(
            [
                tx("Pay", day: 1, month: 9, category: "Paychecks", id: "pay", amount: 2000),
                tx("Rent", day: 2, category: "Rent", id: "rent", amount: -800),
                tx("Refund", day: 3, category: "Rent", id: "refund", amount: 25),
                tx("Move", day: 4, category: "Transfer", id: "move", amount: -700),
                paired,
                tx("Unfiled deposit", day: 5, category: nil, id: "unknown", amount: 100)
            ], transfers: [paired.id])
        #expect(summary.income == 2000)
        #expect(summary.spending == 775)
        #expect(summary.months.map(\.month) == [Month(year: 2026, month: 9), Month(year: 2026, month: 10)])
        #expect(summary.months.map(\.income) == [2000, 0])
        #expect(summary.months.map(\.spending) == [0, 775])
        #expect(summary.categories.map(\.category) == ["Rent"])
        #expect(summary.categories.map(\.amount) == [775])
    }

    @Test func eachMonthKeepsItsOwnCategoriesBiggestFirst() {
        let summary = TransactionSearch.summary([
            tx("Rent", day: 1, month: 9, category: "Rent", id: "sep-rent", amount: -800),
            tx("Lunch", day: 2, month: 9, category: "Food", id: "sep-food", amount: -40),
            tx("Groceries", day: 3, category: "Food", id: "oct-food", amount: -120),
            tx("Cab", day: 4, category: "Taxi", id: "oct-cab", amount: -30),
            tx("Refund", day: 5, category: "Taxi", id: "oct-refund", amount: 10)
        ])
        let byMonth = Dictionary(uniqueKeysWithValues: summary.months.map { ($0.month, $0) })
        #expect(byMonth[Month(year: 2026, month: 9)]?.categories.map(\.category) == ["Rent", "Food"])
        #expect(byMonth[Month(year: 2026, month: 10)]?.categories.map(\.category) == ["Food", "Taxi"])
        #expect(byMonth[Month(year: 2026, month: 10)]?.categories.map(\.amount) == [120, 20])
    }

    @Test func summaryKeepsEmptyMonthsAndSplitsRefundsReimbursementsAndGoalPayments() {
        var split = tx("Store", day: 1, month: 8, category: "Food", id: "split", amount: -100)
        split.splits = [.init(category: "Food", amount: -60), .init(category: "Home", amount: -40)]
        var shared = tx("Dinner", day: 2, category: "Food", id: "shared", amount: -50)
        shared.reimbursable = true
        shared.reimbursableAmount = 20
        var goalPaid = tx("Trip", day: 3, category: "Travel", id: "trip", amount: -200)
        goalPaid.paidFromGoal = UUID()
        let summary = TransactionSearch.summary(
            [
                split, shared, goalPaid,
                tx("Returned", day: 4, category: "Home", id: "refund", amount: 60),
                tx("Custom income", day: 5, category: "My work", id: "income", amount: 500)
            ], kinds: ["My work": .income])
        #expect(summary.months.map(\.month) == [Month(year: 2026, month: 8), Month(year: 2026, month: 9), Month(year: 2026, month: 10)])
        #expect(summary.months.map(\.spending) == [100, 0, 170])
        #expect(summary.income == 500)
        #expect(summary.spending == 270)
        #expect(summary.categories.map(\.category) == ["Travel", "Food", "Home"])
        #expect(summary.categories.map(\.amount) == [200, 90, -20])
        #expect(TransactionSearch.summary([]).months.isEmpty)
        #expect(TransactionSearch.summary([]).spending == 0)
    }

    private func tx(
        _ merchant: String, statement: String = "", day: Int, month: Int = 10, category: String?,
        id: String, amount: Decimal = -10
    ) -> Transaction {
        Transaction(
            accountID: account, day: Day(year: 2026, month: month, day: day), amount: amount, merchant: merchant,
            statement: statement, category: category, externalID: id)
    }
}
