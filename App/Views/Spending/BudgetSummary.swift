import Core
import SwiftUI

/// The month in one card: what's left to spend leads (the one figure you
/// act on), then income, expenses and what's left over, then what needs a
/// look: money with no job yet and transactions to tidy up.
struct BudgetSummary: View {
    let sheet: BudgetSheet
    let pace: FlexBudgetMonth
    let month: Month
    let tidyUp: TidyUp
    var goalNames: [UUID: String] = [:]
    @Environment(\.rowDensity) private var density

    private var isCurrentMonth: Bool { month == Month(Day(.now, in: .current)) }
    /// A month still to come shows only what's planned.
    private var isAhead: Bool { month > Month(Day(.now, in: .current)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            flexible
            Rule()
            // Three figures side by side, or stacked when the window is narrow.
            let layout =
                density == .compact
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.l))
            layout {
                figure("Income", actual: sheet.income.actual, detail: "of \(sheet.income.planned.budgetDollars) planned")
                figure("Expenses", actual: sheet.actualExpenses, detail: "of \(sheet.plannedExpenses.budgetDollars) planned")
                figure(
                    isCurrentMonth ? "Left over so far" : "Left over", actual: sheet.actualNet,
                    detail: "\(sheet.plannedNet.budgetDollars) planned for the month")
            }
            if !sheet.paidFromGoals.isEmpty {
                // Spending a goal paid for: real spending, but not the budget's.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(sheet.paidFromGoals.sorted { ($0.value, $1.key.uuidString) > ($1.value, $0.key.uuidString) }, id: \.key) { goal, amount in
                        Text("\(amount.budgetDollars) paid from \(goalNames[goal] ?? "a goal"), not counted in expenses")
                            .privateAmount()
                    }
                }
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            // Only when something needs a look: money left to plan, or bills
            // past income. A fully planned month says nothing.
            if sheet.leftToBudget.map({ $0 != 0 }) == true || !tidyUp.isEmpty {
                Rule()
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if let left = sheet.leftToBudget, left != 0 {
                        LeftToBudgetLine(sheet: sheet, left: left)
                    }
                    TidyUpRows(tidyUp: tidyUp)
                }
            }
        }
        .card(padding: Spacing.l)
    }

    /// "$577 left of $1,800 flexible for October", the meter, and the pace
    /// in words; for a month still to come, only what's planned.
    @ViewBuilder private var flexible: some View {
        let left = pace.flexibleRemaining
        if pace.flexibleBudget > 0 {
            let name = month.monthName
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    if isAhead {
                        Text(pace.flexibleBudget.wholeDollars).font(Typeface.figure).monospacedDigit()
                            .foregroundStyle(Palette.ink).privateAmount()
                        Text("flexible planned for \(name)").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    } else {
                        Text(left >= 0 ? "\(left.wholeDollars) left" : "\((-left).wholeDollars) over")
                            .font(Typeface.figure).monospacedDigit()
                            .foregroundStyle(left >= 0 ? Palette.ink : Palette.failure)
                            .privateAmount()
                        Text("of \(pace.flexibleBudget.wholeDollars) flexible \(isCurrentMonth ? "for" : "in") \(name)")
                            .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .privateAmount()
                    }
                }
                if !isAhead, pace.flexibleSpent > pace.flexibleBudget {
                    // Over: the bar is everything spent, so its two parts are labeled.
                    PaceMeter(
                        spent: pace.flexibleSpent, budget: pace.flexibleBudget, expected: pace.expectedSoFar,
                        tone: pace.standing.tone, showsPace: false)
                    BudgetSplitLabels(split: CGFloat(NSDecimalNumber(decimal: pace.flexibleBudget / pace.flexibleSpent).doubleValue)) {
                        Text("\(pace.flexibleBudget.wholeDollars) budget").privateAmount()
                        Text("\(pace.flexibleSpent.wholeDollars) spent").privateAmount()
                    }
                    .font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
                    .accessibilityElement(children: .combine)
                    if isCurrentMonth {
                        Text(pace.paceInWords)
                            .font(Typeface.detail).foregroundStyle(pace.standing.tone.color)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else if !isAhead {
                    PaceMeter(
                        spent: pace.flexibleSpent, budget: pace.flexibleBudget, expected: pace.expectedSoFar,
                        tone: pace.standing.tone, showsPace: pace.daysLeft > 0)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(pace.flexibleSpent.wholeDollars) spent").monospacedDigit().privateAmount()
                        Spacer(minLength: Spacing.s)
                        if isCurrentMonth {
                            Text(pace.paceInWords)
                                .foregroundStyle(pace.standing.tone == .neutral ? Palette.inkSecondary : pace.standing.tone.color)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
        } else {
            Text("No flexible budget yet. Type one in the Flexible total row, or use Edit budget.")
                .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func figure(_ title: String, actual: Decimal, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            Text(actual.budgetDollars).font(Typeface.section).monospacedDigit().foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .privateAmount()
            Text(detail).font(Typeface.detail).monospacedDigit()
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .privateAmount()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Money in with no category: the way to file it. The total row's note
/// says how much, and stays when the card is collapsed.
struct UnfiledInLine: View {
    let file: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Choose categories for money in", action: file).linkButton().font(Typeface.body)
        }
        .padding(.top, Spacing.s)
    }
}

/// Zero-based budgeting: every planned dollar of income goes to a bill,
/// savings or the flexible budget, which is what's left, so this is $0 (done,
/// green) unless bills and savings are past income (red).
private struct LeftToBudgetLine: View {
    let sheet: BudgetSheet
    let left: Decimal

    private var tone: StatusTone { left > 0 ? .attention : left < 0 ? .over : .good }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: left == 0 ? "checkmark.circle.fill" : left > 0 ? "circle.dashed" : "exclamationmark.circle.fill")
                    .accessibilityHidden(true)
                Text(
                    left == 0
                        ? "Every dollar is planned"
                        : left > 0 ? "\(left.wholeDollars) left to budget" : "\((-left).wholeDollars) planned past your income"
                )
                .monospacedDigit()
            }
            .font(Typeface.body.weight(.semibold))
            .foregroundStyle(tone.color)
            .privateAmount()
            Text(breakdown)
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .privateAmount()
        }
    }

    /// "$5,500 income − $3,097 fixed − $1,963 flexible", and why when bills
    /// and savings are past income.
    private var breakdown: String {
        let sum =
            "\(sheet.income.planned.wholeDollars) income − \(sheet.fixed.planned.wholeDollars) fixed − \(sheet.flexible.budget.wholeDollars) flexible"
            + (sheet.irregular.planned > 0 ? " − \(sheet.irregular.planned.wholeDollars) irregular" : "")
            + (sheet.savings.planned > 0 ? " − \(sheet.savings.planned.wholeDollars) savings" : "")
        return left < 0 ? sum + ". Bills and savings are past your income, so nothing is left for flexible." : sum
    }
}

/// Under an over-budget meter: the budget's label ending where the budget
/// does, and what was spent at the bar's end. When the two would meet, the
/// budget's label slides left rather than overlap.
private struct BudgetSplitLabels: Layout {
    /// Where the budget ends, as a share of the bar.
    let split: CGFloat
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let budget = subviews[0].sizeThatFits(.unspecified), spent = subviews[1].sizeThatFits(.unspecified)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: .unspecified)
        let latest = bounds.maxX - spent.width - spacing
        let end = min(max(bounds.minX + bounds.width * split, bounds.minX + budget.width), latest)
        subviews[0].place(at: CGPoint(x: end, y: bounds.minY), anchor: .topTrailing, proposal: .unspecified)
    }
}
