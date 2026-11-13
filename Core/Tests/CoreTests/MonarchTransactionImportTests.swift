import Core
import Foundation
import Testing

/// Header in Monarch's export format; rows are made up.
@Suite struct MonarchTransactionImportTests {
    let header = "Date,Merchant,Category,Account,Original Statement,Notes,Amount,Tags,Owner,Reviewed,Id"
    func day(_ d: Int) -> Day { Day(year: 2026, month: 10, day: d) }

    func csv(_ rows: String...) -> String { ([header] + rows).joined(separator: "\r\n") + "\r\n" }

    @Test func readsMonarchsTransactionExport() throws {
        let rows = try MonarchTransactionImport.parse(
            csv(
                "2026-10-02,Blue Bottle,Coffee Shops,Everyday Checking (...1234),BLUE BOTTLE #12,,-6.50,,Alex,Reviewed,111",
                "2026-10-01,Acme Corp,Paychecks,Everyday Checking (...1234),ACME PAYROLL,,\"5,000.00\",,Alex,Reviewed,222"
            ))
        #expect(
            rows == [
                ImportedTransaction(
                    day: day(2), merchant: "Blue Bottle", category: "Coffee Shops",
                    accountName: "Everyday Checking (...1234)", statement: "BLUE BOTTLE #12",
                    amount: Decimal(string: "-6.50")!, monarchID: "111"),
                ImportedTransaction(
                    day: day(1), merchant: "Acme Corp", category: "Paychecks",
                    accountName: "Everyday Checking (...1234)", statement: "ACME PAYROLL",
                    amount: 5000, monarchID: "222")
            ])
    }

    @Test func anEmptyMerchantFallsBackToTheStatementAndUncategorizedIsNone() throws {
        let rows = try MonarchTransactionImport.parse(
            csv(
                "2026-10-02,,Uncategorized,Card,SQ *FARMERS MKT,,-12,,Alex,,333"
            ))
        #expect(rows.first?.merchant == "SQ *FARMERS MKT")
        #expect(rows.first?.category == nil)
    }

    @Test func aFileWithoutAnAmountColumnIsRejected() {
        #expect(throws: MonarchTransactionImport.Failure.missingColumn("Amount")) {
            try MonarchTransactionImport.parse("Date,Merchant\r\n2026-10-01,X\r\n")
        }
    }

    @Test func planningMatchesAccountsByNameAndSkipsTransactionsAlreadyImported() throws {
        let checking = Account(name: "Everyday Checking (...1234)", accountClass: .cash, source: .simplefin, externalID: "A")
        let rows = try MonarchTransactionImport.parse(
            csv(
                "2026-10-02,Blue Bottle,Coffee Shops,everyday checking (...1234) ,X,,-6.50,,Alex,,111",
                "2026-10-03,Blue Bottle,Coffee Shops,Everyday Checking (...1234),X,,-7.00,,Alex,,112"
            ))

        let first = MonarchTransactionImport.plan(rows, existing: [checking], knownExternalIDs: [])
        #expect(first.newAccounts.isEmpty)
        #expect(first.transactions.map(\.accountID) == [checking.id, checking.id])
        #expect(first.transactions.map(\.externalID) == ["monarch:111", "monarch:112"])

        let again = MonarchTransactionImport.plan(
            rows, existing: [checking],
            knownExternalIDs: Set(first.transactions.map(\.externalID)))
        #expect(again.transactions.isEmpty)
    }

    @Test func withoutAnIdIdenticalRowsStayDistinctAndReimportStable() throws {
        let noIDHeader = "Date,Merchant,Category,Account,Original Statement,Notes,Amount"
        let text = "\(noIDHeader)\n2026-10-02,Chipotle,Restaurants,Card,CHIPOTLE 0412,,-12.40\n2026-10-02,Chipotle,Restaurants,Card,CHIPOTLE 0412,,-12.40\n"
        let rows = try MonarchTransactionImport.parse(text)
        let plan = MonarchTransactionImport.plan(rows, existing: [], knownExternalIDs: [])
        #expect(Set(plan.transactions.map(\.externalID)).count == 2)
        let replan = MonarchTransactionImport.plan(
            rows, existing: plan.newAccounts,
            knownExternalIDs: Set(plan.transactions.map(\.externalID)))
        #expect(replan.transactions.isEmpty)
    }

    @Test func recognisesWhichMonarchExportAFileIs() {
        #expect(MonarchTransactionImport.isTransactionExport(csv()))
        #expect(!MonarchTransactionImport.isTransactionExport("Date,Balance,Account\r\n2026-10-01,5,X\r\n"))
    }
}
