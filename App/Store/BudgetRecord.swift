import Core
import Foundation
import SwiftData

/// The budget: one row, the schedule stored as JSON. A plan saved before
/// budgets went month by month reads back as every month's.
@Model
final class BudgetRecord {
    var planData: Data

    init(schedule: BudgetSchedule) {
        planData = (try? JSONEncoder().encode(schedule)) ?? Data()
    }

    var schedule: BudgetSchedule {
        (try? JSONDecoder().decode(BudgetSchedule.self, from: planData)) ?? BudgetSchedule(BudgetPlan(flexibleBudget: 0))
    }
}

extension CompassStore {
    func budgetSchedule() throws -> BudgetSchedule {
        try context.fetch(FetchDescriptor<BudgetRecord>()).first?.schedule ?? BudgetSchedule(BudgetPlan(flexibleBudget: 0))
    }

    /// The plan `month` follows, with their paychecks planned from the latest
    /// one that arrived (`Pay.planned`) and the flexible budget as what's left
    /// (`FlexBudget.balanced`). Editing starts from `budgetSchedule`, never this.
    func budgetPlan(for month: Month) throws -> BudgetPlan {
        try budgetPlan(for: month, paychecks: try paychecks(try payProfile()))
    }

    /// With the paychecks already read (the `PayCache`'s), so the main thread
    /// doesn't read every deposit again.
    func budgetPlan(for month: Month, paychecks: [PaycheckDeposit]) throws -> BudgetPlan {
        let planned = Pay.planned(try budgetSchedule().plan(for: month), month: month, profile: try payProfile(), paychecks: paychecks)
        return FlexBudget.balanced(planned, kinds: try kinds())
    }

    func save(_ schedule: BudgetSchedule) throws {
        if let record = try context.fetch(FetchDescriptor<BudgetRecord>()).first {
            record.planData = (try? JSONEncoder().encode(schedule)) ?? record.planData
        } else {
            context.insert(BudgetRecord(schedule: schedule))
        }
        try context.save()
    }
}
