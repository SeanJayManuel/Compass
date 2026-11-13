import Core
import Foundation
import SwiftData

/// What was read from one paystub (never the file). One per deposit date:
/// importing the same stub again replaces it.
@Model
final class PaystubRecord {
    @Attribute(.unique) var depositOrdinal: Int
    var stubData: Data
    var importedAt: Date

    init(_ stub: Paystub) {
        depositOrdinal = stub.depositDate.ordinal
        stubData = (try? JSONEncoder().encode(stub)) ?? Data()
        importedAt = .now
    }

    var stub: Paystub? { try? JSONDecoder().decode(Paystub.self, from: stubData) }
}

/// How they've paid: one row.
@Model
final class PayProfileRecord {
    var profileData: Data
    var updatedAt: Date

    init(_ profile: PayProfile) {
        profileData = (try? JSONEncoder().encode(profile)) ?? Data()
        updatedAt = .now
    }

    var profile: PayProfile { (try? JSONDecoder().decode(PayProfile.self, from: profileData)) ?? PayProfile() }
}

extension CompassStore {
    func paystubs() throws -> [Paystub] {
        try context.fetch(FetchDescriptor<PaystubRecord>(sortBy: [SortDescriptor(\.depositOrdinal)])).compactMap(\.stub)
    }

    /// The profile as they saved it; before they've saved one, with the 401(k) and
    /// stock plan guessed from account names (so None, once chosen, stays).
    func payProfile() throws -> PayProfile {
        try context.fetch(FetchDescriptor<PayProfileRecord>()).first?.profile ?? PayProfile().guessingAccounts(try accounts())
    }

    func save(_ profile: PayProfile) throws {
        if let record = try context.fetch(FetchDescriptor<PayProfileRecord>()).first {
            record.profileData = (try? JSONEncoder().encode(profile)) ?? record.profileData
            record.updatedAt = .now
        } else {
            context.insert(PayProfileRecord(profile))
        }
        try context.save()
    }

    func save(_ stub: Paystub) throws {
        let ordinal = stub.depositDate.ordinal
        try context.delete(model: PaystubRecord.self, where: #Predicate { $0.depositOrdinal == ordinal })
        context.insert(PaystubRecord(stub))
        try context.save()
    }

    func deletePaystub(depositedOn day: Day) throws {
        let ordinal = day.ordinal
        try context.delete(model: PaystubRecord.self, where: #Predicate { $0.depositOrdinal == ordinal })
        try context.save()
    }

    /// The paychecks that arrived: synced deposits filed under their paycheck category.
    func paychecks(_ profile: PayProfile) throws -> [PaycheckDeposit] {
        try Self.paychecks(profile, in: context)
    }

    nonisolated static func paychecks(_ profile: PayProfile, in context: ModelContext) throws -> [PaycheckDeposit] {
        let category: String? = profile.incomeCategory
        var descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.category == category })
        // Paychecks need only the day, amount and category; reading every
        // field back in (notes, splits) was most of the time.
        descriptor.propertiesToFetch = [\.id, \.accountID, \.dayOrdinal, \.amount, \.category]
        return Pay.paychecks(
            in: try context.fetch(descriptor).map { record in
                Transaction(
                    id: record.id, accountID: record.accountID, day: Day(ordinal: record.dayOrdinal), amount: record.amount,
                    merchant: "", category: record.category, externalID: "")
            }, profile: profile)
    }

    /// Payroll's money into their 401(k) and stock plan over `months`, for `Contributions`.
    func payroll(months: ClosedRange<Month>, today: Day) throws -> Payroll {
        try Self.payroll(
            profile: try payProfile(), transactions: try transactions(), kinds: try kinds(),
            months: months, today: today, in: context)
    }

    /// Off the main thread too, for the net worth cache.
    nonisolated static func payroll(
        profile: PayProfile, transactions: [Transaction], kinds: [String: CategoryKind],
        months: ClosedRange<Month>, today: Day, in context: ModelContext
    ) throws -> Payroll {
        var firstBalances: [UUID: Day] = [:]
        for id in [profile.retirementAccountID, profile.stockAccountID].compactMap({ $0 }) {
            var first = FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.accountID == id }, sortBy: [SortDescriptor(\.dayOrdinal)])
            first.fetchLimit = 1
            if let record = try context.fetch(first).first { firstBalances[id] = Day(ordinal: record.dayOrdinal) }
        }
        return Pay.payroll(
            profile: profile, transactions: transactions, firstBalances: firstBalances, kinds: kinds,
            months: months, today: today)
    }
}
