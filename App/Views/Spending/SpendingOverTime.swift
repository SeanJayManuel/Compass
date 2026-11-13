import Charts
import Core
import SwiftData
import SwiftUI

/// The five biggest categories stacked per month, the rest as Other.
/// Hovering a month shows its breakdown underneath; it stays until another
/// month is hovered, so the pointer can move down to it.
/// After they switch view or month, the bars grow in from the left and the
/// breakdown's figures roll; opening Spending draws them at once.
struct SpendingOverTime: View {
    let grid: [CategoryMonths]
    let shownMonth: Month
    /// True once they've switched view or month on this visit to Spending.
    var animates = false
    /// The hovered month, and the month on screen when it was hovered: a
    /// hover doesn't outlive a step to another month.
    @State private var focus: (month: Month, shown: Month)?
    /// The month whose bars have grown in. A new month's bars wait,
    /// uncovered, until this catches up.
    @State private var grownFor: Month?
    @Environment(\.rowDensity) private var density

    private static let other = "Other"

    var body: some View {
        // Uncategorized is always its own series, in amber, so it never takes
        // a series color or hides in Other: the five biggest others get theirs.
        let others = grid.filter { $0.category != Spending.uncategorized }
        let top = Array(others.prefix(5)) + grid.filter { $0.category == Spending.uncategorized }
        let rest = others.dropFirst(5)
        let names = top.map(\.category) + (rest.isEmpty ? [] : [Self.other])
        let palette = Self.colors(for: top.map(\.category))
        let colors = names.map { palette[$0] ?? Palette.otherSeries }
        let focused = focus.flatMap { $0.shown == shownMonth ? $0.month : nil } ?? shownMonth
        // New bars wait hidden until they grow; Reduce Motion draws them at once.
        let grownIn = !animates || Motion.reduced || grownFor == shownMonth
        let rows: [(String, MonthTotal)] =
            top.flatMap { row in row.months.map { (row.category, $0) } }
            + (rest.isEmpty || grid.isEmpty
                ? []
                : (0..<12).map { index in
                    (
                        Self.other,
                        MonthTotal(
                            month: grid[0].months[index].month,
                            total: rest.reduce(0) { $0 + $1.months[index].total })
                    )
                })

        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                // Wraps onto more rows rather than running off the card.
                FlowRow {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        LegendSwatch(color: colors[index], label: name)
                    }
                }
                Chart(rows.indices, id: \.self) { index in
                    let (category, point) = rows[index]
                    BarMark(
                        x: .value("Month", point.month.firstDay.startDate(in: .current), unit: .month),
                        y: .value("Spent", point.total.chartValue), width: .ratio(0.7)
                    )
                    .foregroundStyle(by: .value("Category", category))
                    .opacity(point.month == focused ? 1 : 0.4)
                }
                // The chart is drawn once and uncovered, rather than its bars
                // animated: animating the marks rebuilt the whole chart every
                // frame, about 0.7 s of work for each switch.
                .chartPlotStyle { plot in
                    plot.mask { GrowMask(progress: grownIn ? 1 : 0, columns: grid.first?.months.count ?? 12) }
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 1)) { _ in
                        // "Nov", or "N" where three letters would run together.
                        AxisValueLabel(format: .dateTime.month(density == .compact ? .narrow : .abbreviated), centered: true).font(Typeface.detail)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Palette.rule)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount, format: .currency(code: "USD").notation(.compactName))
                                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).privateAmount()
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let location) = phase, let plot = proxy.plotFrame,
                                    let date: Date = proxy.value(atX: location.x - geometry[plot].origin.x)
                                else { return }
                                // Only the twelve months on the chart.
                                guard let first = grid.first?.months.first?.month, let last = grid.first?.months.last?.month else { return }
                                let month = min(max(Month(Day(date, in: .current)), first), last)
                                // No animation: animating the change redrew the whole chart
                                // every frame for a quarter second, about five times the work.
                                if month != focused { focus = (month, shownMonth) }
                            }
                    }
                }
                .frame(height: 260 * TextSize.current.scale)
                Text("Point at a month to see where it went.").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            .card(padding: Spacing.l)

            MonthBreakdown(
                month: focused, grid: grid,
                colorFor: { palette[$0] }, shownMonth: shownMonth, rolls: animates
            )
            .card(padding: Spacing.l)
        }
        .onAppear { if animates { grow() } else { grownFor = shownMonth } }
        .onChange(of: shownMonth) { if animates { grow() } else { grownFor = shownMonth } }
    }

    /// The bars grow from the left (see `GrowMask`). A switch part way
    /// through starts the new month's bars from nothing.
    private func grow() {
        withAnimation(Motion.switchIn) { grownFor = shownMonth }
    }

    /// The series colors in order for the categories shown, skipping
    /// Uncategorized, which is amber: it needs a look, it isn't a category.
    private static func colors(for categories: [String]) -> [String: Color] {
        var next = 0
        var colors: [String: Color] = [:]
        for category in categories {
            if category == Spending.uncategorized {
                colors[category] = Palette.attention
            } else {
                colors[category] = Palette.series(next)
                next += 1
            }
        }
        return colors
    }
}

/// Uncovers each month's column of the chart from the bottom, the leftmost
/// first. Over `Motion.switchIn`'s 0.4 s each column takes 0.24 s, easing
/// out, and the last starts 0.16 s after the first. Only this shape changes
/// each frame, so the chart itself is drawn once.
nonisolated private struct GrowMask: Shape {
    private static let spread = 0.4

    var progress: Double
    let columns: Int

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard columns > 0, progress < 1 else { return Path(rect) }
        let width = rect.width / Double(columns)
        let lag = columns > 1 ? Self.spread / Double(columns - 1) : 0
        let span = 1 - lag * Double(columns - 1)
        var path = Path()
        for column in 0..<columns {
            let own = min(max((progress - lag * Double(column)) / span, 0), 1)
            let height = rect.height * (1 - pow(1 - own, 3))
            path.addRect(CGRect(x: rect.minX + width * Double(column), y: rect.maxY - height, width: width, height: height))
        }
        return path
    }
}

/// One month's spending by category; a category opens to show its charges.
private struct MonthBreakdown: View {
    let month: Month
    let grid: [CategoryMonths]
    /// The category's chart color; nil when the chart folds it into Other,
    /// so its row shows no swatch rather than one shared gray.
    let colorFor: (String) -> Color?
    /// The month the chart ends at, and whether the month's total rolls when
    /// that changes. Never on a hover: rolling each step of a scrub redrew the
    /// digits on the CPU every frame. Never while amounts are hidden. Only the
    /// total: rolling every category's figure as well held the main thread
    /// for up to a second at a time.
    let shownMonth: Month
    let rolls: Bool
    @State private var open: String?
    @AppStorage(HideAmounts.key) private var hidden = false

    var body: some View {
        let lines = grid.compactMap { row -> (String, Decimal)? in
            guard let total = row.months.first(where: { $0.month == month })?.total, total > 0 else { return nil }
            return (row.category, total)
        }
        .sorted { $0.1 > $1.1 }
        let total = lines.reduce(Decimal(0)) { $0 + $1.1 }
        let roll = rolls && !hidden && !Motion.reduced

        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.name).font(Typeface.section).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(total.wholeDollars) spent").font(Typeface.body).monospacedDigit()
                    .foregroundStyle(Palette.inkSecondary)
                    .contentTransition(roll ? .numericText(value: total.chartValue) : .identity)
                    .animation(roll ? Motion.change : nil, value: shownMonth)
                    .privateAmount()
            }
            if lines.isEmpty {
                Text("No spending recorded in \(month.name).").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            }
            ForEach(lines, id: \.0) { category, amount in
                VStack(alignment: .leading, spacing: 0) {
                    Rule()
                    Button {
                        withAnimation(Motion.change) { open = open == category ? nil : category }
                    } label: {
                        HStack(spacing: Spacing.s) {
                            RoundedRectangle(cornerRadius: 3).fill(colorFor(category) ?? .clear)
                                .frame(width: 10 * TextSize.current.scale, height: 10 * TextSize.current.scale)
                                .accessibilityHidden(true)
                            Text(category).foregroundStyle(Palette.ink)
                            Text((amount / max(total, 1)).formatted(.percent.precision(.fractionLength(0))))
                                .foregroundStyle(Palette.inkSecondary)
                            Spacer()
                            Text(amount.dollars).monospacedDigit().foregroundStyle(Palette.ink).privateAmount()
                            Image(systemName: open == category ? "chevron.up" : "chevron.down")
                                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                        }
                        .font(Typeface.body)
                        .padding(.vertical, Spacing.s)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if open == category {
                        CategoryCharges(month: month, category: category).padding(.leading, 18).padding(.bottom, Spacing.s)
                    }
                }
            }
        }
    }
}
