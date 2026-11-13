import Core
import Foundation
import Testing

@Suite struct TransactionSyncTests {
    let accessURL = "https://user:secret@bridge.example/simplefin"
    let utc = TimeZone(identifier: "UTC")!

    @Test func askingForTransactionsSendsAStartDateInsteadOfBalancesOnly() async throws {
        let bridge = FakeBridge(status: 200, body: try FakeBridge.fixture("accounts-v2-transactions"))
        let client = SimpleFINClient(transport: bridge.transport)

        _ = try await client.fetchAccounts(accessURL: accessURL, transactionsSince: Date(timeIntervalSince1970: 1_790_000_000))

        #expect(
            bridge.requests.first?.url?.absoluteString
                == "https://bridge.example/simplefin/accounts?version=2&start-date=1790000000")
    }

    @Test func onlyPostedTransactionsComeBackWithPayeePreferred() async throws {
        let client = SimpleFINClient(transport: FakeBridge(status: 200, body: try FakeBridge.fixture("accounts-v2-transactions")).transport)
        let set = try await client.fetchAccounts(accessURL: accessURL, transactionsSince: .distantPast)
        #expect(
            set.accounts.first?.transactions == [
                SimpleFINTransaction(
                    id: "TRN-1", posted: Date(timeIntervalSince1970: 1_792_800_000),
                    amount: Decimal(string: "-6.50")!, payee: "Blue Bottle", description: "BLUE BOTTLE #12"),
                SimpleFINTransaction(
                    id: "TRN-2", posted: Date(timeIntervalSince1970: 1_792_700_000),
                    amount: 5000, payee: "ACME PAYROLL", description: "ACME PAYROLL")
            ])
    }

    /// Later syncs overlap a month: a 401(k) buy dated Oct 22, 2026
    /// never synced, most likely because it reached the Bridge more than a
    /// week after the newest card charge (round 3).
    @Test func theFirstSyncReachesBackNinetyDaysAndLaterOnesOverlapAMonth() {
        let today = Day(year: 2026, month: 10, day: 31)
        #expect(SyncMerge.transactionWindowStart(lastSynced: nil, today: today) == Day(ordinal: today.ordinal - 89))
        #expect(
            SyncMerge.transactionWindowStart(lastSynced: Day(year: 2026, month: 10, day: 30), today: today)
                == Day(year: 2026, month: 9, day: 30))
        // Never more than the Bridge's 90 days.
        #expect(
            SyncMerge.transactionWindowStart(lastSynced: Day(ordinal: today.ordinal - 200), today: today)
                == Day(ordinal: today.ordinal - 89))
    }

    @Test func newTransactionsAreDatedFiledAndDeduplicated() {
        let checking = Account(name: "Checking", accountClass: .cash, source: .simplefin, externalID: "ACT-checking")
        let remote = SimpleFINAccount(
            id: "ACT-checking", name: "Checking", institution: nil, balance: 1, balanceDate: .now,
            transactions: [
                SimpleFINTransaction(
                    id: "TRN-1", posted: Date(timeIntervalSince1970: 1_792_800_000),
                    amount: -6.5, payee: "Blue Bottle", description: "BLUE BOTTLE #12"),
                SimpleFINTransaction(
                    id: "TRN-2", posted: Date(timeIntervalSince1970: 1_792_700_000),
                    amount: 5000, payee: "ACME PAYROLL", description: "ACME PAYROLL")
            ]
        )
        var rules = CategoryRules()
        rules.file(merchant: "Blue Bottle", as: "Coffee Shops")

        let new = SyncMerge.newTransactions(
            fetched: [remote], accounts: [checking], knownExternalIDs: ["simplefin:ACT-checking:TRN-2"],
            rules: rules, timeZone: utc, today: Day(year: 2026, month: 12, day: 1))

        #expect(new.count == 1)
        #expect(new.first?.externalID == "simplefin:ACT-checking:TRN-1")
        #expect(new.first?.accountID == checking.id)
        #expect(new.first?.category == "Coffee Shops")
        #expect(new.first?.day == Day(Date(timeIntervalSince1970: 1_792_800_000), in: utc))
    }

    @Test func theSameTransactionIDOnTwoAccountsIsTwoTransactions() {
        let a = Account(name: "A", accountClass: .cash, source: .simplefin, externalID: "ACT-A")
        let b = Account(name: "B", accountClass: .cash, source: .simplefin, externalID: "ACT-B")
        let posted = Date(timeIntervalSince1970: 1_792_800_000)
        func remote(_ id: String) -> SimpleFINAccount {
            SimpleFINAccount(
                id: id, name: id, institution: nil, balance: 0, balanceDate: posted,
                transactions: [SimpleFINTransaction(id: "1", posted: posted, amount: -5, payee: "X", description: "X")])
        }
        let new = SyncMerge.newTransactions(
            fetched: [remote("ACT-A"), remote("ACT-B")], accounts: [a, b], knownExternalIDs: [],
            rules: CategoryRules(), timeZone: utc, today: Day(year: 2026, month: 12, day: 1))
        #expect(Set(new.map(\.externalID)).count == 2)
    }

    // MARK: Imported and synced copies of the same transaction

    func transaction(_ account: UUID, _ day: Int, _ amount: Decimal, _ externalID: String, category: String? = nil) -> Transaction {
        Transaction(
            accountID: account, day: Day(year: 2026, month: 10, day: day), amount: amount,
            merchant: "X", category: category, externalID: externalID)
    }

    @Test func anImportedAndASyncedCopyWithinThreeDaysArePaired() {
        let account = UUID()
        let imported = transaction(account, 10, -42, "monarch:1", category: "Groceries")
        let synced = transaction(account, 12, -42, "simplefin:A:9")
        #expect(TransactionDedupe.pairs(in: [imported, synced]) == [DuplicatePair(imported: imported.id, synced: synced.id)])
    }

    @Test func differentAmountsAccountsOrDistantDaysAreNotPaired() {
        let account = UUID()
        let imported = transaction(account, 10, -42, "monarch:1")
        #expect(TransactionDedupe.pairs(in: [imported, transaction(account, 10, -41, "simplefin:A:1")]).isEmpty)
        #expect(TransactionDedupe.pairs(in: [imported, transaction(UUID(), 10, -42, "simplefin:A:2")]).isEmpty)
        #expect(TransactionDedupe.pairs(in: [imported, transaction(account, 14, -42, "simplefin:A:3")]).isEmpty)
    }

    @Test func twoIdenticalPurchasesPairOneToOne() {
        let account = UUID()
        let importedA = transaction(account, 10, -5, "monarch:1")
        let importedB = transaction(account, 10, -5, "monarch:2")
        let synced = transaction(account, 10, -5, "simplefin:A:1")
        #expect(TransactionDedupe.pairs(in: [importedA, importedB, synced]).count == 1)
    }
}
