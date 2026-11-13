import Core
import Foundation
import SwiftData

extension CompassStore {
    func backupBundle(at date: Date = .now) throws -> BackupBundle {
        try Self.backupBundle(in: context, at: date)
    }

    /// Everything in the store, read through `context`. Nonisolated, so Back
    /// Up Now can read in a context of its own off the main thread: on the M6
    /// data that's 91,300 balances and 30,000 transactions to fetch and
    /// convert. The same reads as `accounts()`, `transactions()`, `rules()`
    /// and the rest, which are main-actor methods.
    nonisolated static func backupBundle(in context: ModelContext, at date: Date) throws -> BackupBundle {
        let rules = Dictionary(
            try context.fetch(FetchDescriptor<CategoryRuleRecord>()).map { ($0.merchantKey, $0.category) },
            uniquingKeysWith: { first, _ in first })
        let kinds = Dictionary(
            try context.fetch(FetchDescriptor<CategoryKindRecord>()).compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return BackupBundle(
            exportedAt: date,
            accounts: try context.fetch(FetchDescriptor<AccountRecord>()).map(\.account),
            snapshots: try context.fetch(FetchDescriptor<SnapshotRecord>()).map(\.snapshot),
            transactions: try context.fetch(FetchDescriptor<TransactionRecord>()).map(\.transaction),
            goals: try context.fetch(FetchDescriptor<GoalRecord>(sortBy: [SortDescriptor(\.createdAt)])).map(\.goal),
            budget: try context.fetch(FetchDescriptor<BudgetRecord>()).first?.schedule,
            categoryRules: CategoryRules(rules).all,
            categoryKinds: kinds,
            lifeGoals: try context.fetch(FetchDescriptor<LifeGoalRecord>(sortBy: [SortDescriptor(\.createdAt)])).compactMap(\.goal),
            habits: try context.fetch(FetchDescriptor<HabitRecord>(sortBy: [SortDescriptor(\.createdAt)])).compactMap(\.habit),
            list: try context.fetch(FetchDescriptor<ListItemRecord>()).map(\.item),
            vision: try context.fetch(FetchDescriptor<VisionRecord>()).first?.text ?? "",
            reminderMeasures: try context.fetch(FetchDescriptor<ReminderMeasureRecord>()).compactMap(\.link),
            playbook: try context.fetch(FetchDescriptor<PlaybookEntryRecord>(sortBy: [SortDescriptor(\.createdAt)])).compactMap(\.entry),
            sizes: try context.fetch(FetchDescriptor<PlaybookSizesRecord>()).first?.sizes ?? PlaybookSizes(),
            yearlyBets: try context.fetch(FetchDescriptor<YearlyBetsRecord>(sortBy: [SortDescriptor(\.year)])).map(\.bets),
            paystubs: try context.fetch(FetchDescriptor<PaystubRecord>(sortBy: [SortDescriptor(\.depositOrdinal)])).compactMap(\.stub),
            pay: try context.fetch(FetchDescriptor<PayProfileRecord>()).first?.profile ?? PayProfile(),
            notes: try context.fetch(FetchDescriptor<NoteRecord>()).compactMap(\.note)
        )
    }

    /// Writes a dated folder inside `folder`: the full bundle as JSON, plus
    /// balances and transactions as CSVs. Returns the new folder.
    @discardableResult
    func exportBackup(into folder: URL, at date: Date = .now) throws -> URL {
        let bundle = try backupBundle(at: date)
        let day = Day(date, in: .current)
        var destination = folder.appending(path: String(format: "Compass Backup %04d-%02d-%02d", day.year, day.month, day.dayOfMonth))
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appending(path: String(format: "Compass Backup %04d-%02d-%02d %d", day.year, day.month, day.dayOfMonth, suffix))
            suffix += 1
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Backup.json(bundle).write(to: destination.appending(path: "compass-backup.json"), options: .atomic)
        try Data(Backup.balancesCSV(snapshots: bundle.snapshots, accounts: bundle.accounts).utf8)
            .write(to: destination.appending(path: "balances.csv"), options: .atomic)
        try Data(Backup.transactionsCSV(bundle.transactions, accounts: bundle.accounts, goals: bundle.goals).utf8)
            .write(to: destination.appending(path: "transactions.csv"), options: .atomic)
        return destination
    }
}
