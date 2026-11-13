import Core
import Foundation
import SwiftData

/// A change Claude made through the endpoint, stored as JSON beside its id
/// like habits. Not in the backup: undo works against live Reminders and
/// Calendar, which a restore on another Mac wouldn't have.
@Model
final class ClaudeActivityRecord {
    @Attribute(.unique) var id: UUID
    var at: Date
    var activityData: Data

    init(_ activity: ClaudeActivity) {
        id = activity.id
        at = activity.at
        activityData = (try? JSONEncoder().encode(activity)) ?? Data()
    }

    var activity: ClaudeActivity? { try? JSONDecoder().decode(ClaudeActivity.self, from: activityData) }
}

extension CompassStore {
    /// Newest first.
    func claudeActivity() throws -> [ClaudeActivity] {
        try context.fetch(FetchDescriptor<ClaudeActivityRecord>(sortBy: [SortDescriptor(\.at, order: .reverse)])).compactMap(\.activity)
    }

    func save(_ activity: ClaudeActivity) throws {
        let id = activity.id
        var descriptor = FetchDescriptor<ClaudeActivityRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.activityData = (try? JSONEncoder().encode(activity)) ?? record.activityData
        } else {
            context.insert(ClaudeActivityRecord(activity))
        }
        try context.save()
    }

    func deleteGoal(_ id: UUID) throws {
        try context.delete(model: GoalRecord.self, where: #Predicate { $0.id == id })
        try context.save()
    }

    func deleteHabit(_ id: UUID) throws {
        try context.delete(model: HabitRecord.self, where: #Predicate { $0.id == id })
        try context.save()
    }

    /// The balance typed by hand for an account on a day, if there is one.
    func manualSnapshot(for accountID: UUID, on day: Day) throws -> BalanceSnapshot? {
        let ordinal = day.ordinal, manual = BalanceSource.manual.rawValue
        var descriptor = FetchDescriptor<SnapshotRecord>(
            predicate: #Predicate {
                $0.accountID == accountID && $0.dayOrdinal == ordinal && $0.sourceRaw == manual
            })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.snapshot
    }

    func add(_ account: Account, opening: BalanceSnapshot) throws {
        context.insert(AccountRecord(account))
        try upsert(opening)
        try context.save()
    }

    /// Removes an account Claude made while it holds only its opening
    /// balance and no transactions; false otherwise.
    func deleteUntouchedAccount(_ id: UUID, opening: BalanceSnapshot) throws -> Bool {
        let snapshots = try context.fetch(FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.accountID == id })).map(\.snapshot)
        var transactions = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.accountID == id })
        transactions.fetchLimit = 1
        guard snapshots == [opening], try context.fetchCount(transactions) == 0 else { return false }
        try context.delete(model: SnapshotRecord.self, where: #Predicate { $0.accountID == id })
        try context.delete(model: AccountRecord.self, where: #Predicate { $0.id == id })
        try context.save()
        return true
    }

    func saveManualSnapshot(_ snapshot: BalanceSnapshot) throws {
        try upsert(snapshot)
        try context.save()
    }

    func deleteManualSnapshot(_ snapshot: BalanceSnapshot) throws {
        try delete(snapshot)
        try context.save()
    }
}
