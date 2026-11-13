import Foundation

/// Everything Compass holds, in one file that can be read back. Manual
/// balances on synced accounts (pins) are among the snapshots.
public struct BackupBundle: Hashable, Codable, Sendable {
    public var version = 1
    public var exportedAt: Date
    public var accounts: [Account]
    public var snapshots: [BalanceSnapshot]
    public var transactions: [Transaction]
    public var goals: [Goal]
    public var budget: BudgetSchedule?
    /// Merchant key to category, as learned from filing.
    public var categoryRules: [String: String]
    public var categoryKinds: [String: CategoryKind]
    public var lifeGoals: [LifeGoal]
    public var habits: [Habit]
    public var list: [ListItem]
    public var vision: String
    /// Quarter reminders followed by a number; the reminders themselves stay in Reminders.
    public var reminderMeasures: [ReminderMeasure]
    public var playbook: [PlaybookEntry]
    public var sizes: PlaybookSizes
    public var yearlyBets: [YearlyBets]
    /// What was read from their paystubs (never the files), and how they've paid.
    public var paystubs: [Paystub]
    public var pay: PayProfile
    /// Rules and reasons kept for Claude.
    public var notes: [Note]

    public init(
        exportedAt: Date, accounts: [Account], snapshots: [BalanceSnapshot], transactions: [Transaction],
        goals: [Goal], budget: BudgetSchedule?, categoryRules: [String: String] = [:],
        categoryKinds: [String: CategoryKind] = [:], lifeGoals: [LifeGoal], habits: [Habit], list: [ListItem],
        vision: String, reminderMeasures: [ReminderMeasure] = [],
        playbook: [PlaybookEntry] = [], sizes: PlaybookSizes = PlaybookSizes(), yearlyBets: [YearlyBets] = [],
        paystubs: [Paystub] = [], pay: PayProfile = PayProfile(), notes: [Note] = []
    ) {
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.snapshots = snapshots
        self.transactions = transactions
        self.goals = goals
        self.budget = budget
        self.categoryRules = categoryRules
        self.categoryKinds = categoryKinds
        self.lifeGoals = lifeGoals
        self.habits = habits
        self.list = list
        self.vision = vision
        self.reminderMeasures = reminderMeasures
        self.playbook = playbook
        self.sizes = sizes
        self.yearlyBets = yearlyBets
        self.paystubs = paystubs
        self.pay = pay
        self.notes = notes
    }
}

extension BackupBundle {
    /// Older backups, written before quarter reminders could follow a number,
    /// the Playbook, yearly bets, pay or notes, read back with none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        accounts = try container.decode([Account].self, forKey: .accounts)
        snapshots = try container.decode([BalanceSnapshot].self, forKey: .snapshots)
        transactions = try container.decode([Transaction].self, forKey: .transactions)
        goals = try container.decode([Goal].self, forKey: .goals)
        budget = try container.decodeIfPresent(BudgetSchedule.self, forKey: .budget)
        categoryRules = try container.decode([String: String].self, forKey: .categoryRules)
        categoryKinds = try container.decode([String: CategoryKind].self, forKey: .categoryKinds)
        lifeGoals = try container.decode([LifeGoal].self, forKey: .lifeGoals)
        habits = try container.decode([Habit].self, forKey: .habits)
        list = try container.decode([ListItem].self, forKey: .list)
        vision = try container.decode(String.self, forKey: .vision)
        reminderMeasures = try container.decodeIfPresent([ReminderMeasure].self, forKey: .reminderMeasures) ?? []
        playbook = try container.decodeIfPresent([PlaybookEntry].self, forKey: .playbook) ?? []
        sizes = try container.decodeIfPresent(PlaybookSizes.self, forKey: .sizes) ?? PlaybookSizes()
        yearlyBets = try container.decodeIfPresent([YearlyBets].self, forKey: .yearlyBets) ?? []
        paystubs = try container.decodeIfPresent([Paystub].self, forKey: .paystubs) ?? []
        pay = try container.decodeIfPresent(PayProfile.self, forKey: .pay) ?? PayProfile()
        notes = try container.decodeIfPresent([Note].self, forKey: .notes) ?? []
    }
}

/// The backup export: a JSON bundle plus CSVs that open in any spreadsheet.
public enum Backup {
    /// The automatic backup's file for a day; one a day, replaced through it.
    public static func dailyName(for day: Day) -> String {
        String(format: "compass-backup-%04d-%02d-%02d.json", day.year, day.month, day.dayOfMonth)
    }

    /// The daily backups among `names` past the newest `keep`. Other files are never listed.
    public static func expiredDaily(_ names: [String], keep: Int) -> [String] {
        let daily = names.filter { $0.hasPrefix("compass-backup-") && $0.hasSuffix(".json") }.sorted()
        return Array(daily.dropLast(keep))
    }

    public static func json(_ bundle: BackupBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    public static func decode(_ data: Data) throws -> BackupBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupBundle.self, from: data)
    }

    public static func balancesCSV(snapshots: [BalanceSnapshot], accounts: [Account]) -> String {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = snapshots.sorted { ($0.day, byID[$0.accountID]?.name ?? "") < ($1.day, byID[$1.accountID]?.name ?? "") }
            .map { snapshot in
                let account = byID[snapshot.accountID]
                return [
                    date(snapshot.day), account?.name ?? "", account?.institution ?? "", snapshot.source.rawValue,
                    amount(snapshot.balance)
                ]
            }
        return table(header: ["Date", "Account", "Institution", "Source", "Balance"], rows: rows)
    }

    public static func transactionsCSV(_ transactions: [Transaction], accounts: [Account], goals: [Goal] = []) -> String {
        let names = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let goalNames = Dictionary(goals.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let rows = transactions.sorted { $0.day > $1.day }.map { transaction in
            [
                date(transaction.day), names[transaction.accountID] ?? "", transaction.merchant, transaction.statement,
                transaction.category ?? "", amount(transaction.amount),
                transaction.splits.map { "\($0.category) \(amount($0.amount))" }.joined(separator: "; "),
                transaction.paidFromGoal.map { "\(goalNames[$0] ?? "A goal") \(amount(transaction.paidByGoal))" } ?? ""
            ]
        }
        return table(header: ["Date", "Account", "Merchant", "Statement", "Category", "Amount", "Splits", "Paid from goal"], rows: rows)
    }

    /// Exact to the cent, with no grouping and a dot for decimals.
    public static func amount(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        let text = "\(rounded)"
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let cents = parts.count > 1 ? String(parts[1]) : ""
        return "\(parts[0]).\(cents.padding(toLength: 2, withPad: "0", startingAt: 0))"
    }

    public static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func table(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(csvField).joined(separator: ",") + "\n" }.joined()
    }

    private static func date(_ day: Day) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.dayOfMonth)
    }
}
