import Core
import SwiftUI

/// The month's budget, laid out like Monarch's budget page: income, fixed
/// bills and flexible spending, each planned against actual with what
/// remains, with what's left to spend and the totals on top. Planned amounts
/// are typed in place.
struct BudgetSheetView: View {
    let sheet: BudgetSheet
    /// For naming savings lines, which are accounts, and offering more.
    let accounts: [Account]
    /// The month shown, so the summary knows whether it's still going.
    let month: Month
    /// What's left of the flexible budget and its pace, and each bill's usual day.
    let pace: FlexBudgetMonth
    /// Every month's plan: a typed amount applies from this month on.
    let schedule: BudgetSchedule
    /// What needs a look, listed in the summary card.
    let tidyUp: TidyUp
    /// Income planned from pay rather than typed, by category: how it was planned.
    var incomeNotes: [String: String] = [:]
    /// For naming the goals that paid for spending this month.
    var goalNames: [UUID: String] = [:]
    let save: (BudgetSchedule) -> Void
    /// Opens the filing sheet, for money in that has no category yet.
    let fileUnfiled: () -> Void
    @Remembered("spending.showUnbudgeted") private var showUnbudgeted = false
    /// The category whose charges are open under its row; one at a time.
    @State private var openCategory: String?

    var body: some View {
        // A group with nothing planned shows its unbudgeted lines anyway, so
        // income can be planned from the start; the toggle covers the rest.
        let hidden =
            (sheet.income.lines.isEmpty ? 0 : sheet.income.unbudgeted.count)
            + (sheet.fixed.lines.isEmpty ? 0 : sheet.fixed.unbudgeted.count)
        let usualDay = Dictionary(pace.bills.map { ($0.category, $0.usualDay) }, uniquingKeysWith: { first, _ in first })
        let months = MonthPlanning(schedule: schedule, month: month) { commit($0) }

        VStack(alignment: .leading, spacing: Spacing.m) {
            BudgetSummary(sheet: sheet, pace: pace, month: month, tidyUp: tidyUp, goalNames: goalNames)

            if hidden > 0 {
                HStack {
                    Spacer()
                    Button(showUnbudgeted ? "Hide unbudgeted" : "Show \(hidden) unbudgeted") {
                        withAnimation(Motion.change) { showUnbudgeted.toggle() }
                    }
                    .linkButton()
                    .font(Typeface.body)
                    .help("Categories with money in or out this month but nothing planned")
                }
            }

            BudgetGroupCard(
                title: "Income", totalTitle: "Total income", key: "income", month: month, open: $openCategory, moneyIn: true,
                months: months, amount: { .income($0) },
                actions: { line in
                    line.planned == nil
                        ? [
                            BudgetRowAction(title: "Plan \(Self.dollars(line.actual).wholeDollars) a month") {
                                _ = commit(.income(line.category), Self.dollars(line.actual))
                            }
                        ]
                        : [BudgetRowAction(title: "Stop planning") { _ = commit(.income(line.category), nil) }]
                },
                lines: sheet.income.lines + (showUnbudgeted || sheet.income.lines.isEmpty ? sheet.income.unbudgeted : []),
                planned: sheet.income.planned, actual: sheet.income.actual,
                remaining: { line in .income(planned: line.planned, actual: line.actual) },
                total: .incomes(planned: sheet.income.planned, outstanding: sheet.income.outstanding, extra: sheet.income.overPlan),
                totalNote: Self.totalNote(
                    over: sheet.income.overPlan, overWord: "more than planned",
                    outstanding: sheet.income.outstanding, unbudgeted: sheet.income.unbudgetedActual,
                    unfiled: sheet.unfiledIn),
                note: { line in incomeNotes[line.category] },
                empty: "No income yet this month. Type what you expect next to a category once it arrives.",
                commit: { category, amount in commit(.income(category), amount) }
            ) {
                if sheet.unfiledIn > 0 {
                    UnfiledInLine(file: fileUnfiled)
                }
            }

            BudgetGroupCard(
                title: "Fixed", totalTitle: "Total fixed", key: "fixed", month: month, open: $openCategory,
                months: months, amount: { .bill($0) },
                actions: { line in
                    let category = line.category
                    let toFlexible = BudgetRowAction(title: "Move to flexible") {
                        _ = commit(schedule.changing(month, .onward) { $0.roles[category] = .flexible })
                    }
                    let toIrregular = BudgetRowAction(title: "Move to irregular") {
                        _ = commit(
                            schedule.changing(month, .onward) {
                                $0.roles[category] = .irregular; $0.expected[category] = nil
                            })
                    }
                    // Nothing paid yet: they type the amount instead.
                    let planAsPaid =
                        line.actual == 0
                        ? []
                        : [
                            BudgetRowAction(title: "Plan \(Self.dollars(line.actual).wholeDollars) a month") {
                                _ = commit(.bill(category), Self.dollars(line.actual))
                            }
                        ]
                    return line.planned == nil
                        ? planAsPaid + [toFlexible, toIrregular]
                        : [
                            toFlexible, toIrregular,
                            BudgetRowAction(title: "Stop planning") {
                                // It stays in view as unbudgeted, to plan again.
                                if commit(.bill(category), nil) { showUnbudgeted = true }
                            }
                        ]
                },
                lines: sheet.fixed.lines + (showUnbudgeted || sheet.fixed.lines.isEmpty ? sheet.fixed.unbudgeted : []),
                planned: sheet.fixed.planned, actual: sheet.fixed.actual,
                remaining: { line in .bill(planned: line.planned, actual: line.actual) },
                total: .bills(planned: sheet.fixed.planned, outstanding: sheet.fixed.outstanding, over: sheet.fixed.overPlan),
                totalNote: Self.totalNote(
                    over: sheet.fixed.overPlan, overWord: "over plan",
                    outstanding: sheet.fixed.outstanding, unbudgeted: sheet.fixed.unbudgetedActual,
                    unfiled: 0),
                note: { line in
                    guard line.actual == 0, let day = usualDay[line.category] ?? nil else { return nil }
                    return "Usually around the \(Self.ordinal(day))"
                },
                empty: "No fixed bills yet. Mark categories like rent and internet as fixed in Edit budget.",
                commit: { category, amount in commit(.bill(category), amount) }
            ) { EmptyView() }

            FlexibleCard(
                group: sheet.flexible, isRemainder: sheet.income.planned > 0, month: month, months: months,
                open: $openCategory,
                actions: { line in
                    // Uncategorized isn't a category to move.
                    guard line.category != Spending.uncategorized else { return [] }
                    let category = line.category, usual = Self.dollars(line.actual)
                    return [
                        BudgetRowAction(title: "Move to fixed") {
                            // Planned at what it came to this month, so it shows as a bill.
                            _ = commit(
                                schedule.changing(month, .onward) {
                                    $0.roles[category] = .fixed
                                    if $0.expected[category] == nil { $0.expected[category] = usual }
                                })
                        },
                        BudgetRowAction(title: "Move to irregular") {
                            // An annual fee or charity: out of the flexible budget and its pace.
                            _ = commit(schedule.changing(month, .onward) { $0.roles[category] = .irregular })
                        }
                    ]
                }
            ) { amount in
                commit(.flexible, amount)
            }

            if !(sheet.irregular.lines + sheet.irregular.unbudgeted).isEmpty {
                BudgetGroupCard(
                    title: "Irregular", totalTitle: "Total irregular", key: "irregular", month: month, open: $openCategory,
                    months: months, amount: { .bill($0) },
                    actions: { line in
                        let category = line.category
                        return [
                            BudgetRowAction(title: "Move to flexible") {
                                _ = commit(
                                    schedule.changing(month, .onward) {
                                        $0.roles[category] = .flexible; $0.expected[category] = nil
                                    })
                            }
                        ] + (line.planned == nil ? [] : [BudgetRowAction(title: "Stop planning") { _ = commit(.bill(category), nil) }])
                    },
                    lines: sheet.irregular.lines + sheet.irregular.unbudgeted,
                    planned: sheet.irregular.planned, actual: sheet.irregular.actual,
                    remaining: { line in line.planned == nil ? nil : .bill(planned: line.planned, actual: line.actual) },
                    total: .bills(planned: sheet.irregular.planned, outstanding: sheet.irregular.outstanding, over: sheet.irregular.overPlan),
                    totalNote: "Not part of the flexible budget or its pace.",
                    note: { _ in nil },
                    empty: "",
                    commit: { category, amount in commit(.bill(category), amount) }
                ) { EmptyView() }
            }

            savingsCard(months: months)
        }
    }

    /// Money moved into savings and investing accounts, one line an account.
    /// Planned lines show from the start, so a new month can be planned;
    /// an investing account they moved money into with no plan shows too.
    private func savingsCard(months: MonthPlanning) -> some View {
        let names = Dictionary(accounts.map { ($0.id.uuidString, $0.name) }, uniquingKeysWith: { first, _ in first })
        let listed = Set((sheet.savings.lines + sheet.savings.unbudgeted).map(\.category))
        let addable = accounts.filter { account in
            account.accountClass != .debt && !listed.contains(account.id.uuidString)
                && (account.archivedOn.map { $0 > Day(.now, in: .current) } ?? true)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return BudgetGroupCard(
            title: "Savings", totalTitle: "Total savings", key: "savings", month: month, open: $openCategory,
            months: months, amount: { .saving(UUID(uuidString: $0) ?? UUID()) },
            displayName: { names[$0] ?? "Closed account" }, opensCharges: false,
            actions: { line in
                guard let id = UUID(uuidString: line.category) else { return [] }
                return [BudgetRowAction(title: "Remove from savings") { _ = commit(.saving(id), nil) }]
            },
            lines: sheet.savings.lines + sheet.savings.unbudgeted,
            planned: sheet.savings.planned, actual: sheet.savings.actual,
            remaining: { line in .saving(planned: line.planned, actual: line.actual) },
            total: .saved(planned: sheet.savings.planned, outstanding: sheet.savings.outstanding, extra: sheet.savings.overPlan),
            totalNote: nil,
            note: { _ in nil },
            empty: "Add the accounts you move money into, to plan how much goes to each.",
            commit: { id, amount in UUID(uuidString: id).map { commit(.saving($0), amount) } ?? false }
        ) {
            if !addable.isEmpty {
                Menu("Add an account") {
                    ForEach(addable) { account in
                        Button(account.name) { _ = commit(.saving(account.id), 0) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().tint(Palette.needleText)
                .font(Typeface.body)
                .padding(.top, Spacing.m)
            }
        }
    }

    /// An amount to the dollar, for planning a line at what it came to.
    static func dollars(_ amount: Decimal) -> Decimal {
        var amount = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &amount, 0, .plain)
        return rounded
    }

    /// Saves a typed amount from this month on.
    private func commit(_ amount: BudgetAmount, _ value: Decimal?) -> Bool {
        commit(schedule.setting(amount, to: value, in: month, .onward))
    }

    /// Saves a changed schedule, unless clearing a field would leave nothing
    /// planned and drop Spending back to the setup prompt. Returns whether
    /// it saved, so a refused field goes back to its amount.
    private func commit(_ changed: BudgetSchedule) -> Bool {
        guard !changed.isEmpty else { return false }
        save(changed)
        return true
    }

    /// What the total's pill leaves out: a line over its plan while another
    /// is still short, money with no plan, and money in with no category.
    static func totalNote(over: Decimal, overWord: String, outstanding: Decimal, unbudgeted: Decimal, unfiled: Decimal) -> String? {
        var parts: [String] = []
        // When nothing is outstanding the pill already says how far over it is.
        if over > 0, outstanding > 0 { parts.append("\(over.wholeDollars) \(overWord)") }
        if unbudgeted != 0 { parts.append("\(unbudgeted.budgetDollars) unbudgeted") }
        if unfiled > 0 { parts.append("\(unfiled.wholeDollars) came in with no category, so it isn't income yet") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func ordinal(_ day: Int) -> String {
        let suffix = (11...13).contains(day) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
        return "\(day)\(suffix)"
    }
}

extension View {
    /// Marks an amount this month changed, with its menu.
    func acrossMonths(_ months: MonthPlanning, _ amount: BudgetAmount) -> some View {
        modifier(AcrossMonths(months: months, amount: amount))
    }
}

extension Month {
    /// "November".
    var monthName: String { firstDay.startDate(in: .current).formatted(.dateTime.month(.wide)) }
}

extension Binding<String?> {
    /// Whether this category is the open one; opening it closes any other.
    func opens(_ category: String) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue == category }, set: { wrappedValue = $0 ? category : nil })
    }
}

extension View {
    func chargesUnderRow(indented: Bool = false) -> some View {
        modifier(ChargesUnderRow(indented: indented))
    }
}

extension Decimal {
    /// Whole dollars with a true minus sign: "$2,100" or "−$300".
    var budgetDollars: String { self < 0 ? "−\((-self).wholeDollars)" : wholeDollars }
}
