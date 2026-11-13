import Charts
import Core
import SwiftData
import SwiftUI

/// Holds the scrub position, so hovering re-renders only the headline and
/// chart, never the rest of the money overview.
struct ScrubbableNetWorth: View {
    let series: [DailyTotal]
    let visible: [DailyTotal]
    let markers: [GoalMarker]
    let visibleBreakdown: [DailyBreakdown]
    let accessible: Decimal?
    let today: Day
    @Binding var range: TimeRange
    /// The chart's height at standard text size.
    var chartHeight: CGFloat = 260
    /// The next net worth goal, drawn as a dashed line.
    var target: (name: String, value: Decimal)?
    @AppStorage(NetWorthChartView.key) private var chartView = NetWorthChartView.total
    @State private var scrubbed: DailyTotal?

    /// Long ranges draw the average of each stretch of days, so day-to-day
    /// swings (a paycheck in, a card paid off) don't read as the trend.
    private let pointLimit = 120

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            // As the draft: the figure and this month's
            // change on the left, assets and what's owed on the right.
            HStack(alignment: .top, spacing: Spacing.l) {
                Headline(
                    series: series, visible: visible, scrubbed: scrubbed, today: today, accessible: accessible,
                    chartView: $chartView)
                Spacer(minLength: Spacing.m)
                if let latest = visibleBreakdown.last { AssetsAndOwed(latest: latest) }
            }
            if visible.count > 1 {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Group {
                        switch chartView {
                        case .total:
                            NetWorthChart(
                                series: NetWorthSeries.averaged(visible, toAtMost: pointLimit),
                                exact: visible, markers: markers, target: target, scrubbed: $scrubbed
                            )
                            .perfMark("netWorth.chart")
                        case .byClass:
                            ByClassChart(breakdown: NetWorthSeries.averaged(visibleBreakdown, toAtMost: pointLimit))
                        case .monthlyChange:
                            MonthlyChangeChart(
                                changes: NetWorthSeries.monthlyChange(series, from: range.start(endingOn: today)),
                                monthEnds: MonthlyChangeChart.monthEnds(series), today: today)
                        }
                    }
                    // Taller with larger text, so legends and axis labels
                    // don't squeeze the plot.
                    .frame(height: chartHeight * TextSize.current.scale)
                    .transition(.opacity)
                }
                .onChange(of: chartView) { _, _ in scrubbed = nil }
                .onChange(of: range) { _, _ in scrubbed = nil }
            }
        }
    }
}

/// The three ways to look at net worth over time, switched with ⌘1 to ⌘3.
/// Where it sits today is its own card under the chart.
enum NetWorthChartView: String, CaseIterable {
    case total, byClass, monthlyChange

    static let key = "netWorth.view"

    /// The full name, for the Chart menu.
    var title: String {
        switch self {
        case .total: "Total"
        case .byClass: "By Class"
        case .monthlyChange: "Monthly Change"
        }
    }

    /// A short label that fits beside the range picker.
    var shortTitle: String {
        switch self {
        case .total: "Total"
        case .byClass: "By class"
        case .monthlyChange: "Monthly"
        }
    }
}

struct NetWorthViewCommands: Commands {
    @AppStorage(NetWorthChartView.key) private var chartView = NetWorthChartView.total

    var body: some Commands {
        CommandMenu("Chart") {
            ForEach(Array(NetWorthChartView.allCases.enumerated()), id: \.element) { index, option in
                Button(option.title) { withAnimation(Motion.change) { chartView = option } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
    }
}

/// The one big number. While scrubbing it shows the hovered day instead.
private struct Headline: View {
    let series: [DailyTotal]
    let visible: [DailyTotal]
    let scrubbed: DailyTotal?
    let today: Day
    let accessible: Decimal?
    @Binding var chartView: NetWorthChartView

    var body: some View {
        figures
    }

    private var figures: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Which day the number is for, and which view the chart shows.
            HStack(spacing: Spacing.s) {
                Text(scrubbed.map { "On \($0.day.startDate(in: .current).formatted(date: .long, time: .omitted))" } ?? "Net worth")
                    .font(Typeface.detail)
                    .foregroundStyle(Palette.inkSecondary)
                Menu {
                    Picker("Chart", selection: $chartView) {
                        ForEach(NetWorthChartView.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(chartView.shortTitle).font(Typeface.detail)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Total, by class, or each month's change (⌘1 to ⌘3)")
                .accessibilityLabel("Chart: \(chartView.title)")
            }

            if let shown = scrubbed ?? series.last {
                Text(shown.total.wholeDollars)
                    .font(Typeface.title)
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    // One line always: a narrow window shrinks the figure, never breaks it.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText(value: NSDecimalNumber(decimal: shown.total).doubleValue))
                    // Rolls only when today's total changes. Rolling on every
                    // scrub step, or as the scrub ends when a scroll starts,
                    // redrew the blurred digits on the CPU each frame.
                    .animation(Motion.change, value: series.last?.total)
                    .privateAmount()
                    .help(tip)
                changes(for: shown)
            } else {
                Text("No balances yet")
                    .font(Typeface.hero)
                    .foregroundStyle(Palette.inkSecondary)
                Text("Add an account by hand, or connect SimpleFIN to pull in your banks.")
                    .font(Typeface.body)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    /// This month's change, or the scrubbed day's since the range began.
    private func changes(for shown: DailyTotal) -> some View {
        changeItems(for: shown).font(Typeface.detail)
    }

    /// What the draft's card leaves off, on hover: the year so far and
    /// what's outside retirement accounts.
    private var tip: String {
        var lines: [String] = []
        if let year = NetWorthSeries.change(in: series, since: Day(year: today.year, month: 1, day: 1)) {
            lines.append("\(year.signedWholeDollars) since Jan 1")
        }
        if let accessible, accessible != series.last?.total {
            lines.append("\(accessible.wholeDollars) outside retirement accounts")
        }
        return UserDefaults.standard.bool(forKey: HideAmounts.key) ? "" : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func changeItems(for shown: DailyTotal) -> some View {
        Group {
            if let scrubbed, let start = visible.first {
                change(
                    scrubbed.withoutOpenings - start.withoutOpenings, "since \(start.day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted))"
                )
            } else {
                // Named by its day ("since Sep 21"), not "this month", which
                // would read as the calendar month.
                let monthAgo = today.addingMonths(-1)
                if let month = NetWorthSeries.change(in: series, since: monthAgo) {
                    change(month, "since \(monthAgo.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day()))")
                }
            }
        }
    }

    private func change(_ amount: Decimal, _ label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: amount >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10 * TextSize.current.scale, weight: .semibold))
                .foregroundStyle(amount >= 0 ? Palette.onPace : Palette.failure)
                .accessibilityHidden(true)
            Text(amount.signedWholeDollars)
                .monospacedDigit()
                .foregroundStyle(amount >= 0 ? Palette.onPace : Palette.failure)
                .privateAmount()
            Text(label).foregroundStyle(Palette.inkSecondary)
        }
        .fixedSize()
    }
}

extension Decimal {
    var chartValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

/// Assets and what's owed, at the net worth card's right, as the draft.
private struct AssetsAndOwed: View {
    let latest: DailyBreakdown

    var body: some View {
        let owed = -(latest.byClass[.debt] ?? 0)
        let assets = latest.byClass.filter { $0.key != .debt }.values.reduce(Decimal(0)) { $0 + max($1, 0) }
        HStack(alignment: .top, spacing: Spacing.l) {
            figure("Assets", assets)
            figure("Owed", owed)
        }
    }

    private func figure(_ label: String, _ amount: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            Text(amount.wholeDollars).font(Typeface.body.weight(.medium)).monospacedDigit()
                .foregroundStyle(Palette.ink).privateAmount()
        }
        .accessibilityElement(children: .combine)
    }
}
