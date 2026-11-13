import Charts
import Core
import SwiftData
import SwiftUI

/// Positive account-class totals. Debt lives in the Accounts card, not here.
struct AssetAllocation: View {
    let latest: DailyBreakdown
    /// Beside net worth: as tall as its neighbour.
    var fillsHeight = false

    var body: some View {
        let shares = NetWorthSeries.allocation(latest)
        let assets = shares.reduce(Decimal(0)) { $0 + $1.amount }
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Asset allocation").font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            if shares.isEmpty {
                Text("Add an account with a positive balance to see your allocation.")
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            } else {
                Chart(shares, id: \.accountClass) { part in
                    SectorMark(
                        angle: .value("Assets", part.amount.chartValue),
                        innerRadius: .ratio(0.74), angularInset: 1.5
                    )
                    .cornerRadius(2)
                    .foregroundStyle(Palette.accountClass(part.accountClass))
                }
                // The total in the ring, as in the draft.
                .chartBackground { _ in
                    VStack(spacing: 2) {
                        Text("Assets").font(Typeface.caption).foregroundStyle(Palette.inkSecondary)
                        Text(assets.wholeDollars).font(Typeface.body.weight(.medium)).monospacedDigit()
                            .foregroundStyle(Palette.ink).privateAmount()
                            .minimumScaleFactor(0.7).lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.l)
                }
                .frame(height: 150 * TextSize.current.scale)
                // The rows below read each class; the ring itself reads the total.
                .accessibilityElement()
                .accessibilityLabel("\(assets.wholeDollars) in assets")
                ForEach(shares, id: \.accountClass) { part in
                    HStack(spacing: Spacing.s) {
                        LegendSwatch.mark(color: Palette.accountClass(part.accountClass)).accessibilityHidden(true)
                        Text(part.accountClass.label)
                        Spacer(minLength: Spacing.xs)
                        Text(part.share.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    }
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .card(padding: Spacing.m)
    }
}

struct LegendSwatch: View {
    let color: Color
    let label: String
    var dashed = false
    /// An outline over a light wash, for hollow marks.
    var hollow = false

    /// How strong the wash inside a hollow mark is.
    static let hollowWash = 0.25
    /// A hollow mark's outline.
    static let hollowOutline: CGFloat = 1.5

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Self.mark(color: color, dashed: dashed, hollow: hollow)
            Text(label).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        }
    }

    /// The swatch alone, for a tooltip.
    @ViewBuilder
    static func mark(color: Color, dashed: Bool = false, hollow: Bool = false) -> some View {
        if dashed {
            Capsule().stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2])).frame(width: 14, height: 2)
        } else if hollow {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(hollowWash))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: hollowOutline))
                .frame(width: 10, height: 10)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
        }
    }
}
