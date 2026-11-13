import Foundation

public struct ImportedBalance: Hashable, Sendable {
    public var accountName: String
    public var day: Day
    public var balance: Decimal

    public init(accountName: String, day: Day, balance: Decimal) {
        self.accountName = accountName
        self.day = day
        self.balance = balance
    }
}

public struct ImportPlan: Hashable, Sendable {
    public var newAccounts: [Account]
    /// Keyed by account, day and source like sync, so importing the same file
    /// again rewrites the same snapshots.
    public var snapshots: [BalanceSnapshot]
}

/// Reads Monarch's balance history exports and maps them onto accounts.
public enum MonarchBalanceImport {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case missingColumn(String)
        case badDate(line: Int, text: String)
        case badAmount(line: Int, text: String)

        public var errorDescription: String? {
            switch self {
            case .missingColumn(let name): "This file has no \(name) column, so it doesn't look like a Monarch balance export."
            case .badDate(let line, let text): "Line \(line) has a date Compass can't read: \"\(text)\"."
            case .badAmount(let line, let text): "Line \(line) has an amount Compass can't read: \"\(text)\"."
            }
        }
    }

    /// Three layouts parse: `Date,Balance,Account`; `Date,Balance` with the
    /// account named by the file; and a wide file with a column per account.
    public static func parse(_ text: String, fileName: String) throws -> [ImportedBalance] {
        let csv = CSV(text)
        guard let dateColumn = csv.column("date") else { throw Failure.missingColumn("Date") }

        let accountColumns: [(name: String?, index: Int)]
        let accountNameColumn: Int?
        if let balanceColumn = csv.column("balance") ?? csv.column("amount") {
            accountColumns = [(nil, balanceColumn)]
            accountNameColumn = csv.column("account")
        } else {
            accountColumns = csv.header.indices.filter { $0 != dateColumn }.map { (csv.header[$0], $0) }
            accountNameColumn = nil
        }
        let fallbackName = (fileName as NSString).deletingPathExtension

        var balances: [ImportedBalance] = []
        for row in csv.rows {
            func cell(_ index: Int) -> String { row.fields.indices.contains(index) ? row.fields[index] : "" }
            let dateText = cell(dateColumn)
            guard let day = CSVValue.day(dateText) else { throw Failure.badDate(line: row.line, text: dateText) }
            for (columnName, index) in accountColumns {
                switch CSVValue.amount(cell(index)) {
                case .blank: continue
                case .unreadable: throw Failure.badAmount(line: row.line, text: cell(index))
                case .value(let balance):
                    let name =
                        columnName
                        ?? accountNameColumn.map { cell($0).trimmingCharacters(in: .whitespaces) }
                        ?? fallbackName
                    balances.append(ImportedBalance(accountName: name.isEmpty ? fallbackName : name, day: day, balance: balance))
                }
            }
        }
        return balances
    }

    /// Matches names to accounts (ignoring case and surrounding spaces) and
    /// creates manual accounts for the rest. Debts end up negative: Monarch
    /// already signs them that way, so a file with any negative balance for a
    /// debt keeps its signs (an overpaid card stays positive); a file that
    /// writes debts as positive amounts is flipped.
    public static func plan(_ balances: [ImportedBalance], existing: [Account]) -> ImportPlan {
        var byName = Dictionary(existing.map { (key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let signs = Dictionary(grouping: balances, by: { key($0.accountName) }).mapValues { rows in
            (negative: rows.filter { $0.balance < 0 }.count, total: rows.count)
        }
        var newAccounts: [Account] = []
        var snapshots: [BalanceSnapshot] = []
        for imported in balances {
            let name = key(imported.accountName)
            let sign = signs[name]!
            let account: Account
            if let known = byName[name] {
                account = known
            } else {
                let trimmed = imported.accountName.trimmingCharacters(in: .whitespaces)
                var accountClass = guessClass(from: trimmed)
                if accountClass == .otherAssets, sign.negative * 2 > sign.total { accountClass = .debt }
                account = Account(name: trimmed, accountClass: accountClass, source: .manual)
                byName[name] = account
                newAccounts.append(account)
            }
            let fileSignsDebts = account.accountClass == .debt && sign.negative > 0
            snapshots.append(
                BalanceSnapshot(
                    accountID: account.id,
                    day: imported.day,
                    source: .imported,
                    balance: fileSignsDebts ? imported.balance : account.accountClass.storedBalance(entered: imported.balance)
                ))
        }
        return ImportPlan(newAccounts: newAccounts, snapshots: snapshots)
    }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A first guess from the account's name; it can be changed afterwards.
    static func guessClass(from name: String) -> AccountClass {
        let lowered = name.lowercased()
        let rules: [(AccountClass, [String])] = [
            (.retirement, ["401", "403", "ira", "roth", "pension", "retirement"]),
            (.equity, ["espp", "rsu", "stock plan", "equity"]),
            (.debt, ["credit", "card", "loan", "mortgage", "visa", "amex", "mastercard"]),
            (.taxable, ["brokerage", "invest", "etf", "index"]),
            (.cash, ["checking", "savings", "cash", "money market", "hysa"])
        ]
        return rules.first { _, words in words.contains { lowered.contains($0) } }?.0 ?? .otherAssets
    }
}
