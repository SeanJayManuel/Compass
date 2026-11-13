import Core
import Foundation
import Testing

/// Header layouts follow Monarch's "Download balance history" export as the
/// earlier attempt saw it. Confirm against a real export.
@Suite struct MonarchImportTests {
    func day(_ y: Int, _ m: Int, _ d: Int) -> Day { Day(year: y, month: m, day: d) }

    @Test func readsTheDateBalanceAccountLayout() throws {
        let csv = """
            Date,Balance,Account
            2026-10-01,"1,234.56",Everyday Checking
            2026-10-02,1300,Everyday Checking
            2026-10-02,-450.10,Rewards Card
            """
        let rows = try MonarchBalanceImport.parse(csv, fileName: "balances.csv")
        #expect(
            rows == [
                ImportedBalance(accountName: "Everyday Checking", day: day(2026, 10, 1), balance: Decimal(string: "1234.56")!),
                ImportedBalance(accountName: "Everyday Checking", day: day(2026, 10, 2), balance: 1300),
                ImportedBalance(accountName: "Rewards Card", day: day(2026, 10, 2), balance: Decimal(string: "-450.10")!)
            ])
    }

    @Test func withoutAnAccountColumnTheFileNameIsTheAccount() throws {
        let rows = try MonarchBalanceImport.parse("Date,Balance\n2026-10-01,500\n", fileName: "High-Yield Savings.csv")
        #expect(rows.map(\.accountName) == ["High-Yield Savings"])
    }

    @Test func readsTheWideLayoutWithOneColumnPerAccount() throws {
        let csv = "Date,Checking,Visa\n2026-10-01,100,-20\n2026-10-02,,-25\n"
        let rows = try MonarchBalanceImport.parse(csv, fileName: "x.csv")
        #expect(
            rows == [
                ImportedBalance(accountName: "Checking", day: day(2026, 10, 1), balance: 100),
                ImportedBalance(accountName: "Visa", day: day(2026, 10, 1), balance: -20),
                ImportedBalance(accountName: "Visa", day: day(2026, 10, 2), balance: -25)
            ])
    }

    @Test(arguments: [
        ("$1,000.00", Decimal(1000)),
        ("(250.50)", Decimal(string: "-250.50")!),
        ("-12", Decimal(-12)),
        (" 7 ", Decimal(7))
    ])
    func amountsAsMonarchWritesThem(text: String, expected: Decimal) throws {
        let rows = try MonarchBalanceImport.parse("Date,Balance\n2026-10-01,\"\(text)\"\n", fileName: "a.csv")
        #expect(rows.first?.balance == expected)
    }

    @Test(arguments: ["2026-10-01", "2026-10-01T00:00:00", "2026-10-01 00:00:00", "10/1/2026", "10/01/26"])
    func datesAsMonarchWritesThem(text: String) throws {
        let rows = try MonarchBalanceImport.parse("Date,Balance\n\(text),1\n", fileName: "a.csv")
        #expect(rows.first?.day == day(2026, 10, 1))
    }

    @Test func toleratesAByteOrderMarkWindowsLineEndingsAndBlankRows() throws {
        let csv = "\u{FEFF}Date,Balance,Account\r\n2026-10-01,5,\"Savings, joint\"\r\n,,\r\n"
        let rows = try MonarchBalanceImport.parse(csv, fileName: "a.csv")
        #expect(rows == [ImportedBalance(accountName: "Savings, joint", day: day(2026, 10, 1), balance: 5)])
    }

    @Test func aQuoteInsideAnUnquotedFieldIsKeptAsText() throws {
        let csv = "Date,Balance,Account\n2026-10-01,5,TV 55\" fund\n2026-10-02,6,Savings\n"
        let rows = try MonarchBalanceImport.parse(csv, fileName: "a.csv")
        #expect(rows.map(\.accountName) == ["TV 55\" fund", "Savings"])
    }

    @Test func aBadDateNamesItsLine() {
        #expect(throws: MonarchBalanceImport.Failure.badDate(line: 3, text: "Feb 30")) {
            try MonarchBalanceImport.parse("Date,Balance\n2026-10-01,1\nFeb 30,2\n", fileName: "a.csv")
        }
    }

    @Test func aFileWithoutADateColumnIsRejected() {
        #expect(throws: MonarchBalanceImport.Failure.missingColumn("Date")) {
            try MonarchBalanceImport.parse("When,Balance\n2026-10-01,1\n", fileName: "a.csv")
        }
    }

    // MARK: Planning the import

    @Test func balancesGoToTheMatchingAccountByName() {
        let checking = Account(name: "Everyday Checking", accountClass: .cash, source: .simplefin, externalID: "A")
        let plan = MonarchBalanceImport.plan(
            [ImportedBalance(accountName: "  everyday checking ", day: day(2026, 1, 1), balance: 10)],
            existing: [checking]
        )
        #expect(plan.newAccounts.isEmpty)
        #expect(plan.snapshots == [BalanceSnapshot(accountID: checking.id, day: day(2026, 1, 1), source: .imported, balance: 10)])
    }

    @Test func newAccountsGetAClassFromTheirName() {
        let names = ["Work 401(k)", "Roth IRA", "Brokerage", "ESPP", "Sapphire Credit Card", "Checking", "Car"]
        let plan = MonarchBalanceImport.plan(
            names.map { ImportedBalance(accountName: $0, day: day(2026, 1, 1), balance: 1) },
            existing: []
        )
        #expect(plan.newAccounts.map(\.accountClass) == [.retirement, .retirement, .taxable, .equity, .debt, .cash, .otherAssets])
        #expect(plan.newAccounts.allSatisfy { $0.source == .manual })
    }

    @Test func debtsAreStoredNegativeWhateverTheFileSays() {
        let card = Account(name: "Card", accountClass: .debt, source: .manual)
        let plan = MonarchBalanceImport.plan(
            [ImportedBalance(accountName: "Card", day: day(2026, 1, 1), balance: 300)],
            existing: [card]
        )
        #expect(plan.snapshots.first?.balance == -300)
    }

    @Test func anUnrecognisedAccountThatIsMostlyNegativeIsFiledAsDebt() {
        let rows = [Decimal(-500), -450, -480, 20].enumerated().map {
            ImportedBalance(accountName: "Sapphire Preferred", day: day(2026, 1, $0.offset + 1), balance: $0.element)
        }
        #expect(MonarchBalanceImport.plan(rows, existing: []).newAccounts.map(\.accountClass) == [.debt])
    }

    @Test func aDebtFileThatAlreadySignsDebtsNegativeKeepsAnOverpaymentPositive() {
        let card = Account(name: "Card", accountClass: .debt, source: .manual)
        let rows = [
            ImportedBalance(accountName: "Card", day: day(2026, 1, 1), balance: -300),
            ImportedBalance(accountName: "Card", day: day(2026, 1, 2), balance: 25)
        ]
        #expect(MonarchBalanceImport.plan(rows, existing: [card]).snapshots.map(\.balance) == [-300, 25])
    }

    @Test func importingTheSameFileTwiceTargetsTheSameSnapshots() {
        let rows = [ImportedBalance(accountName: "Savings", day: day(2026, 1, 1), balance: 10)]
        let first = MonarchBalanceImport.plan(rows, existing: [])
        let second = MonarchBalanceImport.plan(rows, existing: first.newAccounts)
        #expect(second.newAccounts.isEmpty)
        #expect(second.snapshots == first.snapshots)
    }
}
