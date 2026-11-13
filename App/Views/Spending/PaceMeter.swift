import Core
import SwiftUI

/// Spent so far against the budget. Within it, the bar is the budget and
/// a tick marks where an even pace would be today. Past it, the bar is
/// everything spent: the budget's share in the accent, a gap where the
/// budget ends, and the overspend in red, so how far over reads at a glance.
struct PaceMeter: View {
    let spent: Decimal
    let budget: Decimal
    let expected: Decimal
    let tone: StatusTone
    let showsPace: Bool
    /// The bar's height at standard text size; the Money tile's is slimmer.
    var thickness: CGFloat = 12

    var body: some View {
        let height = thickness * TextSize.current.scale
        let over = budget > 0 && spent > budget
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                if over {
                    // The budget's end, as a share of everything spent.
                    let budgetEnd = width * share(budget, of: spent)
                    let gap: CGFloat = 2
                    UnevenRoundedRectangle(topLeadingRadius: height / 2, bottomLeadingRadius: height / 2)
                        .fill(Palette.progress)
                        .frame(width: max(budgetEnd - gap / 2, 0))
                    UnevenRoundedRectangle(bottomTrailingRadius: height / 2, topTrailingRadius: height / 2)
                        .fill(Palette.failure)
                        .frame(width: max(width - budgetEnd - gap / 2, height / 2))
                        .offset(x: min(budgetEnd + gap / 2, width - height / 2))
                } else {
                    Capsule().fill(Palette.progressTrack)
                    Capsule().fill(tone == .neutral ? Palette.progress : tone.color)
                        .frame(width: spent > 0 ? max(width * share(spent, of: budget), height) : 0)
                    if showsPace {
                        PaceTick(height: height + 8)
                            .offset(x: width * share(expected, of: budget) - PaceTick.width / 2)
                    }
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 8)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let percent = Int(NSDecimalNumber(decimal: min(spent / max(budget, 1), 9) * 100).doubleValue)
        return "\(percent) percent of the flexible budget spent"
    }

    /// `part` as a share of `whole`, 0 to 1.
    private func share(_ part: Decimal, of whole: Decimal) -> CGFloat {
        guard whole > 0 else { return 0 }
        return CGFloat(NSDecimalNumber(decimal: min(max(part / whole, 0), 1)).doubleValue)
    }
}

extension FlexStanding {
    /// Neutral within pace, amber ahead of it, red over the budget.
    var tone: StatusTone {
        switch self {
        case .withinPace: .neutral
        case .fasterThanPace: .attention
        case .overBudget: .over
        }
    }
}

extension FlexBudgetMonth {
    /// The pace in words, under the meter: "Over budget with 4 days left".
    var paceInWords: String {
        switch standing {
        case .withinPace: "Within an even pace"
        case .fasterThanPace: "Spending faster than an even pace"
        case .overBudget:
            daysLeft > 1
                ? "Over budget with \(daysLeft) days left"
                : daysLeft == 1 ? "Over budget with today left" : "Over budget"
        }
    }
}
