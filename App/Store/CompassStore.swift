import Core
import CoreData
import Foundation
import SwiftData
import os

/// Which data the app is using. `--sandbox` keeps test data in its own store
/// and its own Keychain entry, so it never mixes with real money.
enum DataEnvironment {
    case real
    case sandbox

    static var current: DataEnvironment {
        CommandLine.arguments.contains("--sandbox") ? .sandbox : .real
    }

    var storeURL: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Compass", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name =
            switch self {
            case .real: "Compass.store"
            // Demo data for design review gets its own store, so it never mixes
            // with the sandbox store used for the checklist.
            case .sandbox:
                CommandLine.arguments.contains("--seed-perf")
                    ? "Compass-Perf.store"
                    : CommandLine.arguments.contains("--seed-demo") ? "Compass-Demo.store" : "Compass-Sandbox.store"
            }
        return folder.appending(path: name)
    }

    /// Where the daily backups go: beside the store, in the app's own container.
    var dailyBackupFolder: URL {
        storeURL.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
    }

    var keychainAccount: String {
        self == .sandbox ? "simplefin-access-url.sandbox" : "simplefin-access-url"
    }
}

/// Reads and writes the SwiftData store in Core's terms.
struct CompassStore {
    let context: ModelContext

    static func container(for environment: DataEnvironment) throws -> ModelContainer {
        try container(at: environment.storeURL)
    }

    /// Every model in the store. One taken out on purpose also goes in `retired`.
    static let models: [any PersistentModel.Type] = [
        AccountRecord.self, SnapshotRecord.self, SyncRunRecord.self, GoalRecord.self,
        TransactionRecord.self, CategoryRuleRecord.self, CategoryKindRecord.self, BudgetRecord.self,
        LifeGoalRecord.self, ListItemRecord.self, VisionRecord.self, HabitRecord.self,
        ReminderMeasureRecord.self, ClaudeActivityRecord.self, PlaybookEntryRecord.self, PlaybookSizesRecord.self,
        YearlyBetsRecord.self, PaystubRecord.self, PayProfileRecord.self, NoteRecord.self
    ]

    /// Models and fields removed on purpose ("Model" or "Model.field"), which
    /// opening an older store may drop.
    static let retired: Set<String> = []

    /// The store holds models or fields this build doesn't know: it's older
    /// than the data, and opening the store would delete them.
    struct Refused: LocalizedError {
        let url: URL
        let unknown: [String]
        var errorDescription: String? {
            "This copy of Compass is older than its data (\(url.lastPathComponent) has \(unknown.joined(separator: ", ")), which it doesn't know). Opening it would delete them, so it stopped without opening. Open the newest Compass instead."
        }
    }

    /// Opens the store, refusing (without touching it) when it holds models or
    /// fields `models` doesn't, and records what this build knows beside it.
    static func container(at url: URL, models: [any PersistentModel.Type] = models) throws -> ModelContainer {
        let schema = Schema(models)
        let known = shape(of: schema)
        let unknown = StoreGuard.unknown(in: storedShape(at: url), known: known, retired: retired)
        guard unknown.isEmpty else { throw Refused(url: url, unknown: unknown) }
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        try? JSONEncoder().encode(known).write(to: shapeURL(for: url), options: .atomic)
        return container
    }

    private static func shape(of schema: Schema) -> StoreShape {
        StoreShape(
            Dictionary(
                uniqueKeysWithValues: schema.entities.map { entity in
                    (entity.name, Set(entity.attributes.map(\.name)).union(entity.relationships.map(\.name)))
                }))
    }

    /// The models the store's metadata names, with the fields the last build
    /// to open it recorded. Empty when there's no store yet.
    private static func storedShape(at url: URL) -> StoreShape {
        guard FileManager.default.fileExists(atPath: url.path) else { return StoreShape([:]) }
        var shape = StoreShape([:])
        if let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url),
            let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Any]
        {
            shape = StoreShape(Dictionary(uniqueKeysWithValues: hashes.keys.map { ($0, Set<String>()) }))
        }
        if let data = try? Data(contentsOf: shapeURL(for: url)),
            let recorded = try? JSONDecoder().decode(StoreShape.self, from: data)
        {
            shape = shape.merging(recorded)
        }
        return shape
    }

    private static func shapeURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".shape.json")
    }

    func snapshots() throws -> [BalanceSnapshot] {
        try context.fetch(FetchDescriptor<SnapshotRecord>()).map(\.snapshot)
    }

    func accounts() throws -> [Account] {
        try context.fetch(FetchDescriptor<AccountRecord>()).map(\.account)
    }

    func addManualAccount(name: String, accountClass: AccountClass, balance: Decimal, on day: Day) throws {
        let account = Account(name: name, accountClass: accountClass, source: .manual)
        context.insert(AccountRecord(account))
        try upsert(
            BalanceSnapshot(
                accountID: account.id, day: day, source: .manual,
                balance: accountClass.storedBalance(entered: balance)
            ))
        try context.save()
    }

    func logBalance(_ balance: Decimal, for account: Account, on day: Day) throws {
        try upsert(
            BalanceSnapshot(
                accountID: account.id, day: day, source: .manual,
                balance: account.accountClass.storedBalance(entered: balance)
            ))
        try context.save()
    }

    func apply(_ plan: SyncPlan) throws {
        for account in plan.newAccounts {
            context.insert(AccountRecord(account))
        }
        try upsert(plan.snapshots)
        for pin in plan.pinsToClear {
            try delete(pin)
        }
        try context.save()
    }

    func apply(_ plan: ImportPlan) throws {
        for account in plan.newAccounts {
            context.insert(AccountRecord(account))
        }
        try upsert(plan.snapshots)
        try context.save()
    }

    func update(_ account: Account) throws {
        let id = account.id
        var descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        try context.fetch(descriptor).first?.update(from: account)
        try context.save()
    }

    /// Manual balances on synced accounts, which a sync may clear.
    func pins() throws -> [BalanceSnapshot] {
        let synced = Set(try accounts().filter { $0.source == .simplefin }.map(\.id))
        let manual = BalanceSource.manual.rawValue
        return try context.fetch(FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.sourceRaw == manual }))
            .map(\.snapshot)
            .filter { synced.contains($0.accountID) }
    }

    func removePin(_ pin: BalanceSnapshot) throws {
        try delete(pin)
        try context.save()
    }

    /// Writes many snapshots with one fetch, for imports of years of history.
    private func upsert(_ snapshots: [BalanceSnapshot]) throws {
        guard snapshots.count > 1 else {
            if let snapshot = snapshots.first { try upsert(snapshot) }
            return
        }
        let accountIDs = Array(Set(snapshots.map(\.accountID)))
        let existing = try context.fetch(
            FetchDescriptor<SnapshotRecord>(
                predicate: #Predicate {
                    accountIDs.contains($0.accountID)
                }))
        var byKey = Dictionary(
            existing.map { (SnapshotKey($0.snapshot), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for snapshot in snapshots {
            if let record = byKey[SnapshotKey(snapshot)] {
                record.balance = snapshot.balance
                record.recordedAt = .now
            } else {
                let record = SnapshotRecord(snapshot)
                context.insert(record)
                byKey[SnapshotKey(snapshot)] = record
            }
        }
    }

    func delete(_ snapshot: BalanceSnapshot) throws {
        let accountID = snapshot.accountID
        let ordinal = snapshot.day.ordinal
        let source = snapshot.source.rawValue
        try context.delete(
            model: SnapshotRecord.self,
            where: #Predicate {
                $0.accountID == accountID && $0.dayOrdinal == ordinal && $0.sourceRaw == source
            })
    }

    func upsert(_ snapshot: BalanceSnapshot) throws {
        let accountID = snapshot.accountID
        let ordinal = snapshot.day.ordinal
        let source = snapshot.source.rawValue
        var existing = FetchDescriptor<SnapshotRecord>(
            predicate: #Predicate {
                $0.accountID == accountID && $0.dayOrdinal == ordinal && $0.sourceRaw == source
            })
        existing.fetchLimit = 1
        if let record = try context.fetch(existing).first {
            record.balance = snapshot.balance
            record.recordedAt = .now
        } else {
            context.insert(SnapshotRecord(snapshot))
        }
    }
}

private struct SnapshotKey: Hashable {
    var accountID: UUID
    var ordinal: Int
    var source: BalanceSource

    init(_ snapshot: BalanceSnapshot) {
        accountID = snapshot.accountID
        ordinal = snapshot.day.ordinal
        source = snapshot.source
    }
}

/// Where store problems are logged (Console, subsystem com.compass.store).
nonisolated let storeLog = Logger(subsystem: "com.compass.store", category: "store")

extension ModelContext {
    /// Every record of a type. A failed fetch is logged and reads as none,
    /// as the screens and caches have always treated it.
    nonisolated func all<Record: PersistentModel>(_: Record.Type) -> [Record] {
        do {
            return try fetch(FetchDescriptor<Record>())
        } catch {
            storeLog.error("Couldn't read \(String(describing: Record.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
