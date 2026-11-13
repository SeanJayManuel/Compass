import Core
import SwiftUI

/// Income or fixed bills: a collapsible card with planned, actual and
/// remaining for each category, and a total row that stays when collapsed.
struct BudgetGroupCard<Footer: View>: View {
    let title: String
    let totalTitle: String
    let key: String
    let month: Month
    @Binding var open: String?
    /// Income: its charges read as money in.
    let moneyIn: Bool
    let months: MonthPlanning
    /// Which planned amount a category's field is.
    let amount: (String) -> BudgetAmount
    /// A line's name as shown: savings lines are accounts, by id.
    let displayName: (String) -> String
    /// Categories open their charges; savings accounts don't.
    let opensCharges: Bool
    /// A line's ⋯ menu.
    let actions: (BudgetLine) -> [BudgetRowAction]
    let lines: [BudgetLine]
    let planned: Decimal
    let actual: Decimal
    let remaining: (BudgetLine) -> Remaining?
    let total: Remaining
    let totalNote: String?
    let note: (BudgetLine) -> String?
    let empty: String
    let commit: (String, Decimal?) -> Bool
    @ViewBuilder let footer: () -> Footer
    @Remembered private var collapsed: Bool

    init(
        title: String, totalTitle: String, key: String, month: Month, open: Binding<String?>, moneyIn: Bool = false,
        months: MonthPlanning, amount: @escaping (String) -> BudgetAmount,
        displayName: @escaping (String) -> String = { $0 }, opensCharges: Bool = true,
        actions: @escaping (BudgetLine) -> [BudgetRowAction], lines: [BudgetLine], planned: Decimal, actual: Decimal,
        remaining: @escaping (BudgetLine) -> Remaining?, total: Remaining, totalNote: String?,
        note: @escaping (BudgetLine) -> String?, empty: String, commit: @escaping (String, Decimal?) -> Bool,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.totalTitle = totalTitle
        self.key = key
        self.month = month
        _open = open
        self.moneyIn = moneyIn
        self.months = months
        self.amount = amount
        self.displayName = displayName
        self.opensCharges = opensCharges
        self.actions = actions
        self.lines = lines
        self.planned = planned
        self.actual = actual
        self.remaining = remaining
        self.total = total
        self.totalNote = totalNote
        self.note = note
        self.empty = empty
        self.commit = commit
        self.footer = footer
        _collapsed = Remembered(wrappedValue: false, "spending.collapsed.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: title, collapsed: $collapsed)
            if !collapsed {
                if lines.isEmpty {
                    Rule()
                    Text(empty).font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Spacing.s)
                }
                ForEach(lines, id: \.category) { line in
                    Rule()
                    BudgetRow(
                        name: displayName(line.category), note: note(line), actual: line.actual, remaining: remaining(line),
                        isOpen: opensCharges ? $open.opens(line.category) : nil, actions: actions(line)
                    ) {
                        PlannedField(label: "Planned for \(displayName(line.category))", amount: line.planned) { commit(line.category, $0) }
                            .acrossMonths(months, amount(line.category))
                    }
                    if open == line.category {
                        CategoryCharges(month: month, category: line.category, moneyIn: moneyIn).chargesUnderRow()
                    }
                }
            }
            Rule()
            BudgetRow(name: totalTitle, note: totalNote, isTotal: true, actual: actual, remaining: total) {
                Text(planned.budgetDollars).monospacedDigit().foregroundStyle(Palette.ink).privateAmount()
            }
            if !collapsed { footer() }
        }
        .card(padding: Spacing.l)
    }
}

/// Flexible categories share one budget on the total row, which comes
/// first: with income planned it's what's left after bills and savings,
/// otherwise typed in. What each category spent sits indented beneath it.
/// What's left and the pace are in the summary above.
struct FlexibleCard: View {
    let group: FlexibleGroup
    let isRemainder: Bool
    let month: Month
    let months: MonthPlanning
    @Binding var open: String?
    /// A category's ⋯ menu.
    let actions: (BudgetLine) -> [BudgetRowAction]
    let commit: (Decimal?) -> Bool
    @Remembered("spending.collapsed.flexible") private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: "Flexible", collapsed: $collapsed)
            Rule()
            BudgetRow(
                name: "Total flexible", isTotal: true, actual: group.actual,
                remaining: .spending(budget: group.budget, actual: group.actual)
            ) {
                if isRemainder {
                    Text(group.budget.wholeDollars).monospacedDigit().foregroundStyle(Palette.inkSecondary).privateAmount()
                        .help("What's left of planned income after bills and savings. Change those to change it.")
                        .accessibilityLabel("Flexible budget \(group.budget.wholeDollars), what's left after bills and savings")
                } else {
                    PlannedField(label: "Flexible budget", amount: group.budget > 0 ? group.budget : nil, commit: commit)
                        .acrossMonths(months, .flexible)
                }
            }
            if !collapsed, !group.lines.isEmpty {
                Rule()
                Text("By category").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    .padding(.leading, Spacing.m).padding(.vertical, Spacing.s)
                ForEach(group.lines, id: \.category) { line in
                    Rule()
                    BudgetRow(
                        name: line.category, indented: true, actual: line.actual, remaining: nil,
                        isOpen: $open.opens(line.category), actions: actions(line)
                    ) { EmptyView() }
                    if open == line.category {
                        CategoryCharges(month: month, category: line.category).chargesUnderRow(indented: true)
                    }
                }
            }
        }
        .card(padding: Spacing.l)
    }
}
