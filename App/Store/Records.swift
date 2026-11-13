import Core
import Foundation
import SwiftData

@Model
final class AccountRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var institution: String?
    var classRaw: String
    var sourceRaw: String
    var externalID: String?
    var createdAt: Date
    var excludedFromNetWorth: Bool = false
    var archivedOrdinal: Int?
    /// SimpleFIN feeds merged into this account, which sync skips.
    var mergedExternalIDs: [String] = []

    init(_ account: Account, createdAt: Date = .now) {
        id = account.id
        name = account.name
        institution = account.institution
        classRaw = account.accountClass.rawValue
        sourceRaw = account.source.rawValue
        externalID = account.externalID
        self.createdAt = createdAt
        excludedFromNetWorth = account.excludedFromNetWorth
        archivedOrdinal = account.archivedOn?.ordinal
        mergedExternalIDs = account.mergedExternalIDs
    }

    /// Copies the fields a person can edit.
    func update(from account: Account) {
        name = account.name
        classRaw = account.accountClass.rawValue
        excludedFromNetWorth = account.excludedFromNetWorth
        archivedOrdinal = account.archivedOn?.ordinal
    }

    var account: Account {
        Account(
            id: id,
            name: name,
            institution: institution,
            accountClass: AccountClass(rawValue: classRaw) ?? .otherAssets,
            source: BalanceSource(rawValue: sourceRaw) ?? .manual,
            externalID: externalID,
            excludedFromNetWorth: excludedFromNetWorth,
            archivedOn: archivedOrdinal.map(Day.init(ordinal:)),
            mergedExternalIDs: mergedExternalIDs
        )
    }
}

/// One balance per account, day and source. Writing the same key again
/// replaces the balance, which is what keeps a repeat sync from duplicating.
@Model
final class SnapshotRecord {
    #Unique<SnapshotRecord>([\.accountID, \.dayOrdinal, \.sourceRaw])

    var accountID: UUID
    var dayOrdinal: Int
    var sourceRaw: String
    var balance: Decimal
    var recordedAt: Date

    init(_ snapshot: BalanceSnapshot, recordedAt: Date = .now) {
        accountID = snapshot.accountID
        dayOrdinal = snapshot.day.ordinal
        sourceRaw = snapshot.source.rawValue
        balance = snapshot.balance
        self.recordedAt = recordedAt
    }

    var snapshot: BalanceSnapshot {
        BalanceSnapshot(
            accountID: accountID,
            day: Day(ordinal: dayOrdinal),
            source: BalanceSource(rawValue: sourceRaw) ?? .manual,
            balance: balance
        )
    }
}

@Model
final class SyncRunRecord {
    var startedAt: Date
    var finishedAt: Date?
    var succeeded: Bool
    var accountsUpdated: Int
    var error: String?

    init(startedAt: Date) {
        self.startedAt = startedAt
        succeeded = false
        accountsUpdated = 0
    }
}
