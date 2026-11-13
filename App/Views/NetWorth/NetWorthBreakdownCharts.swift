import Charts
import Core
import SwiftData
import SwiftUI

struct ByClassChart: View {
    let breakdown: [DailyBreakdown]

    /// Assets stack up from zero in this order; debt stacks down from it.
    private static let order: [AccountClass] = [.cash, .taxable, .retirement, .equity, .otherAssets, .debt]

    var body: some View {
        let present = Self.order.filter { accountClass in breakdown.contains { ($0.byClass[accountClass] ?? 0) != 0 } }
        VStack(alignment: .leading, spacing: Spacing.s) {
            // A labeled legend: some class colors are light, so color is never the only cue.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.m, alignment: .leading)],
                alignment: .leading, spacing: Spacing.xs
            ) {
                ForEach(present, id: \.self) { LegendSwatch(color: Palette.accountClass($0), label: $0.label) }
            }
            Chart {
                ForEach(breakdown, id: \.day) { point in
                    ForEach(present, id: \.self) { accountClass in
                        AreaMark(
                            x: .value("Day", point.day.startDate(in: .current)),
                            y: .value("Amount", (point.byClass[accountClass] ?? 0).chartValue),
                            stacking: .standard
                        )
                        .foregroundStyle(by: .value("Class", accountClass.label))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartForegroundStyleScale(domain: present.map(\.label), range: present.map(Palette.accountClass))
            .chartLegend(.hidden)
            .chartXAxis { timeAxis() }
            .chartYAxis { moneyAxis() }
        }
    }
}

/// How much net worth rose or fell each month. Bars go up or down from zero.
/// Rises are solid green; falls are hollow red (an outline over a light
/// wash), so the two never rely on colour alone. Not the accent: a gray
/// accent turned both into shades of gray.
/// Hovering anywhere over a month shows its numbers.
struct MonthlyChangeChart: View {
    @Environment(\.scrollActivity) private var scrollActivity
    private var isScrolling: Bool { scrollActivity?.isScrolling ?? false }
    let changes: [MonthTotal]
    /// Net worth on each month's last day (today, for this month).
    let monthEnds: [Month: Decimal]
    let today: Day
    @State private var hovered: Month?
    @AppStorage(HideAmounts.key) private var amountsHidden = false

    /// A month net worth fell: red, as a rise is green (with a
    /// gray accent, rises and falls were different shades of gray). Falls stay hollow, so they read
    /// apart without color too.
    static let fell = Palette.failure

    /// Each month's last total, in one pass.
    static func monthEnds(_ series: [DailyTotal]) -> [Month: Decimal] {
        var ends: [Month: Decimal] = [:]
        for point in series { ends[Month(point.day)] = point.total }
        return ends
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            legend
            GeometryReader { geometry in
                chart(barWidth: barWidth(in: geometry.size.width))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: Spacing.m) {
            LegendSwatch(color: Palette.onPace, label: "Rose")
            LegendSwatch(color: Self.fell, label: "Fell", hollow: true)
        }
        .fixedSize()
        .help("Each bar is a month's change in net worth. Hover over a month for its numbers.")
    }

    /// Thin bars: at most 24 pt, with air between them.
    private func barWidth(in width: CGFloat) -> CGFloat {
        let plot = max(width - 56, 1)
        return min(24, max(plot / CGFloat(max(changes.count, 1)) * 0.6, 1))
    }

    private func chart(barWidth: CGFloat) -> some View {
        let radius = min(4, barWidth / 2)
        return Chart {
            // The hovered month's whole column, which is also its hit area.
            if let hovered, let change = changes.first(where: { $0.month == hovered }) {
                RectangleMark(x: .value("Month", start(of: hovered), unit: .month), width: .ratio(1))
                    .foregroundStyle(Palette.ink.opacity(0.05))
                    .annotation(
                        position: .overlay, alignment: .top, spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        tooltip(change)
                    }
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(changes, id: \.month) { change in
                let rose = change.total >= 0
                let opacity = hovered == nil || hovered == change.month ? 1.0 : 0.45
                // Rounded at the data end only; square on the zero line.
                let shape = UnevenRoundedRectangle(
                    topLeadingRadius: rose ? radius : 0, bottomLeadingRadius: rose ? 0 : radius,
                    bottomTrailingRadius: rose ? 0 : radius, topTrailingRadius: rose ? radius : 0)
                // Unstacked, so a fall's outline sits over its own wash.
                BarMark(
                    x: .value("Month", start(of: change.month), unit: .month),
                    y: .value("Change", change.total.chartValue), width: .fixed(barWidth), stacking: .unstacked
                )
                .foregroundStyle(rose ? Palette.onPace : Self.fell.opacity(LegendSwatch.hollowWash))
                .opacity(opacity)
                .clipShape(shape)
                .accessibilityLabel(name(of: change.month))
                .accessibilityValue(accessibilityValue(change))
                if !rose {
                    BarMark(
                        x: .value("Month", start(of: change.month), unit: .month),
                        y: .value("Change", change.total.chartValue), width: .fixed(barWidth), stacking: .unstacked
                    )
                    .foregroundStyle(Self.fell)
                    .opacity(opacity)
                    .clipShape(shape.inset(by: LegendSwatch.hollowOutline / 2).stroke(lineWidth: LegendSwatch.hollowOutline))
                    .accessibilityHidden(true)
                }
            }
        }
        .chartXAxis { timeAxis() }
        .chartYAxis { moneyAxis() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    // While the page scrolls, the chart moving under the pointer isn't a scrub.
                    .allowsHitTesting(!isScrolling)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !isScrolling else { return }
                            guard let plot = proxy.plotFrame,
                                let date: Date = proxy.value(atX: location.x - geometry[plot].origin.x)
                            else {
                                if hovered != nil { hovered = nil }
                                return
                            }
                            let month = Month(Day(date, in: .current))
                            let shown = changes.contains { $0.month == month } ? month : nil
                            if shown != hovered { hovered = shown }
                        case .ended:
                            if hovered != nil { hovered = nil }
                        }
                    }
            }
        }
    }

    /// The value leads; the month and where net worth ended follow.
    private func tooltip(_ change: MonthTotal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xs) {
                LegendSwatch.mark(color: change.total >= 0 ? Palette.onPace : Self.fell, hollow: change.total < 0)
                    .accessibilityHidden(true)
                Text(change.total.signedWholeDollars)
                    .font(Typeface.body.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                    .privateAmount()
            }
            Text(name(of: change.month)).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            if let end = monthEnds[change.month] {
                HStack(spacing: Spacing.xs) {
                    Text(change.month == Month(today) ? "Net worth today" : "Ended the month at")
                        .foregroundStyle(Palette.inkSecondary)
                    Text(end.wholeDollars).monospacedDigit().foregroundStyle(Palette.ink).privateAmount()
                }
                .font(Typeface.detail)
            }
        }
        .fixedSize()
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs + 2)
        .background(Palette.surface, in: .rect(cornerRadius: 8))
        .overlay(Hairline(cornerRadius: 8))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.top, Spacing.xs)
    }

    private func accessibilityValue(_ change: MonthTotal) -> String {
        guard !amountsHidden else { return change.total >= 0 ? "Rose" : "Fell" }
        let moved = change.total >= 0 ? "Rose \(change.total.wholeDollars)" : "Fell \((-change.total).wholeDollars)"
        guard let end = monthEnds[change.month] else { return moved }
        return "\(moved), ending at \(end.wholeDollars)"
    }

    private func start(of month: Month) -> Date {
        Day(year: month.year, month: month.month, day: 1).startDate(in: .current)
    }

    private func name(of month: Month) -> String {
        start(of: month).formatted(.dateTime.month(.wide).year())
    }
}
