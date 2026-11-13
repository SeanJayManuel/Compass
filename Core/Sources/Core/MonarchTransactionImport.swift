import Foundation

public struct ImportedTransaction: Hashable, Sendable {
    public var day: Day
    public var merchant: String
    public var category: String?
    public var accountName: String
    public var statement: String
    public var amount: Decimal
    /// Monarch's own transaction ID, from the `Id` column when present.
    public var monarchID: String?

    public init(
        day: Day, merchant: String, category: String?, accountName: String,
        statement: String, amount: Decimal, monarchID: String?
    ) {
        self.day = day
        self.merchant = merchant
        self.category = category
        self.accountName = accountName
        self.statement = statement
        self.amount = amount
        self.monarchID = monarchID
    }
}

public struct TransactionImportPlan: Hashable, Sendable {
    public var newAccounts: [Account]
    /// Only transactions not imported before.
    public var transactions: [Transaction]
}

/// Reads Monarch's "Download transactions" export.
public enum MonarchTransactionImport {
    public typealias Failure = MonarchBalanceImport.Failure

    /// Whether `text` is a transactions export rather than balance history:
    /// it has Amount and Merchant columns and no Balance column.
    public static func isTransactionExport(_ text: String) -> Bool {
        let csv = CSV(String(text.prefix(4096)))
        return csv.column("amount") != nil && csv.column("merchant") != nil && csv.column("balance") == nil
    }

    public static func parse(_ text: String) throws -> [ImportedTransaction] {
        let csv = CSV(text)
        guard let dateColumn = csv.column("date") else { throw Failure.missingColumn("Date") }
        guard let amountColumn = csv.column("amount") else { throw Failure.missingColumn("Amount") }
        let merchantColumn = csv.column("merchant") ?? csv.column("payee") ?? csv.column("description")
        let statementColumn = csv.column("original statement") ?? csv.column("statement")
        let categoryColumn = csv.column("category")
        let accountColumn = csv.column("account")
        let idColumn = csv.header.firstIndex { $0.lowercased() == "id" }

        return try csv.rows.map { row in
            func cell(_ index: Int?) -> String {
                guard let index, row.fields.indices.contains(index) else { return "" }
                return row.fields[index].trimmingCharacters(in: .whitespaces)
            }
            guard let day = CSVValue.day(cell(dateColumn)) else {
                throw Failure.badDate(line: row.line, text: cell(dateColumn))
            }
            guard case .value(let amount) = CSVValue.amount(cell(amountColumn)) else {
                throw Failure.badAmount(line: row.line, text: cell(amountColumn))
            }
            let statement = cell(statementColumn)
            let merchant = cell(merchantColumn)
            let category = cell(categoryColumn)
            let id = cell(idColumn)
            return ImportedTransaction(
                day: day,
                merchant: merchant.isEmpty ? statement : merchant,
                category: category.isEmpty || category.lowercased() == "uncategorized" ? nil : category,
                accountName: cell(accountColumn).isEmpty ? "Imported transactions" : cell(accountColumn),
                statement: statement,
                amount: amount,
                monarchID: id.isEmpty ? nil : id
            )
        }
    }

    /// Matches accounts by name, creates the rest, and leaves out anything
    /// whose external ID is already known, so importing twice adds nothing.
    public static func plan(_ rows: [ImportedTransaction], existing: [Account], knownExternalIDs: Set<String>) -> TransactionImportPlan {
        var byName = Dictionary(existing.map { (MonarchBalanceImport.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var newAccounts: [Account] = []
        var transactions: [Transaction] = []
        var occurrences: [String: Int] = [:]

        for row in rows {
            let nameKey = MonarchBalanceImport.key(row.accountName)
            let account: Account
            if let known = byName[nameKey] {
                account = known
            } else {
                let name = row.accountName.trimmingCharacters(in: .whitespaces)
                account = Account(name: name, accountClass: MonarchBalanceImport.guessClass(from: name), source: .manual)
                byName[nameKey] = account
                newAccounts.append(account)
            }

            let externalID: String
            if let monarchID = row.monarchID {
                externalID = "monarch:\(monarchID)"
            } else {
                // Without Monarch's ID, identical rows on one day are told apart
                // by how many times they've appeared, which is stable on re-import.
                let cents = NSDecimalNumber(decimal: row.amount * 100).intValue
                let base = "monarch:\(row.day.ordinal)|\(cents)|\(Merchant.key(row.merchant))|\(Merchant.key(row.statement))|\(nameKey)"
                occurrences[base, default: 0] += 1
                externalID = "\(base)|\(occurrences[base]!)"
            }
            guard !knownExternalIDs.contains(externalID) else { continue }
            transactions.append(
                Transaction(
                    accountID: account.id, day: row.day, amount: row.amount, merchant: row.merchant,
                    statement: row.statement, category: row.category, externalID: externalID
                ))
        }
        return TransactionImportPlan(newAccounts: newAccounts, transactions: transactions)
    }
}
