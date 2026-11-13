import Charts
import Core
import SwiftData
import SwiftUI

/// Axis labels at the size Swift Charts draws them, scaled with the
/// Settings text size like every other label.
var axisFont: Font { .system(size: 10 * TextSize.current.scale) }

/// Month labels along the bottom, no vertical gridlines. Labels that would
/// overlap in a narrow chart are dropped, not drawn over each other.
func timeAxis() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits), collisionResolution: .greedy)
            .font(axisFont)
            .foregroundStyle(Palette.inkSecondary)
    }
}

/// The trailing dollar axis every net worth chart shares.
func moneyAxis() -> some AxisContent {
    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine().foregroundStyle(Palette.rule)
        AxisValueLabel {
            if let amount = value.as(Double.self) {
                Text(amount, format: .currency(code: "USD").notation(.compactName))
                    .font(axisFont)
                    .foregroundStyle(Palette.inkSecondary)
                    .privateAmount()
            }
        }
    }
}

struct GoalMarker: Identifiable {
    var id: UUID
    var name: String
    var day: Day
    var total: Decimal
}

struct NetWorthChart: View {
    @Environment(\.scrollActivity) private var scrollActivity
    private var isScrolling: Bool { scrollActivity?.isScrolling ?? false }
    /// What's drawn: averaged for long ranges.
    let series: [DailyTotal]
    /// Every day, so scrubbing reads exact values.
    let exact: [DailyTotal]
    var markers: [GoalMarker] = []
    /// The next net worth goal, as the draft's dashed line ("Goal: $210K net worth").
    var target: (name: String, value: Decimal)?
    @Binding var scrubbed: DailyTotal?
    @AppStorage(HideAmounts.key) private var amountsHidden = false

    var body: some View {
        let values = series.map(\.total.chartValue)
        let low = values.min() ?? 0, seriesHigh = values.max() ?? 1
        let margin = max((seriesHigh - low) * 0.12, 1)
        let floor = low - margin
        // Drawn only when the target sits near the line, so reaching up to
        // it never flattens the chart; the domain then makes room for it.
        let goal = target.flatMap { target in
            target.value.chartValue <= seriesHigh + (seriesHigh - low) * 0.5 ? target : nil
        }
        let high = max(seriesHigh, goal?.value.chartValue ?? seriesHigh)
        Chart {
            ForEach(series, id: \.day) { point in
                // The soft fill runs from the bottom of the chart, not from zero.
                AreaMark(
                    x: .value("Day", point.day.startDate(in: .current)),
                    yStart: .value("Floor", floor), yEnd: .value("Net worth", point.total.chartValue)
                )
                // The draft's ink wash, fading toward the floor.
                .foregroundStyle(
                    LinearGradient(
                        colors: [Palette.ink.opacity(0.14), Palette.ink.opacity(0)],
                        startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.catmullRom)
                LineMark(x: .value("Day", point.day.startDate(in: .current)), y: .value("Net worth", point.total.chartValue))
                    .foregroundStyle(Palette.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            if let goal, !amountsHidden {
                RuleMark(y: .value("Goal", goal.value.chartValue))
                    .foregroundStyle(Palette.inkSecondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Goal: \(goal.name)").font(Typeface.caption).foregroundStyle(Palette.inkSecondary)
                    }
                    .accessibilityLabel("Goal: \(goal.name)")
            }
            ForEach(markers) { marker in
                let onLine = (NetWorthSeries.value(on: marker.day, in: series) ?? marker.total).chartValue
                RuleMark(
                    x: .value("Day", marker.day.startDate(in: .current)),
                    yStart: .value("Floor", floor), yEnd: .value("Net worth", onLine)
                )
                .foregroundStyle(Palette.inkSecondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                // Past the middle, the label runs left so it stays on the chart.
                let late = position(of: marker.day) > 0.6
                // On the side the line leaves free, so the label never covers it.
                let below = labelGoesBelow(marker, value: onLine, runsLeft: late, floor: floor, high: high)
                PointMark(x: .value("Day", marker.day.startDate(in: .current)), y: .value("Net worth", onLine))
                    .symbol {
                        Circle().strokeBorder(Palette.ink, lineWidth: 2).background(Circle().fill(Palette.surface)).frame(width: 11, height: 11)
                            // On the symbol, not an annotation: Charts placed an
                            // annotation on a custom symbol about 45 pt away from it.
                            .overlay(alignment: late ? .trailing : .leading) {
                                Text(markerLabel(marker)).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                                    .fixedSize()
                                    // Offset, not alignment guides: guides didn't hold inside a symbol.
                                    .offset(x: (late ? -1 : 1) * Spacing.s, y: (below ? 1 : -1) * 20 * TextSize.current.scale)
                            }
                    }
                    .accessibilityLabel(markerLabel(marker))
            }
            if let last = series.last, scrubbed == nil {
                PointMark(x: .value("Day", last.day.startDate(in: .current)), y: .value("Net worth", last.total.chartValue))
                    .symbol { Circle().fill(Palette.ink).overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2.5)).frame(width: 13, height: 13) }
            }
            if let scrubbed {
                RuleMark(x: .value("Day", scrubbed.day.startDate(in: .current)))
                    .foregroundStyle(Palette.inkSecondary.opacity(0.4))
                // On the drawn line; the headline above shows the exact day.
                PointMark(
                    x: .value("Day", scrubbed.day.startDate(in: .current)),
                    y: .value("Net worth", (NetWorthSeries.value(on: scrubbed.day, in: series) ?? scrubbed.total).chartValue)
                )
                .symbol { Circle().fill(Palette.ink).overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2.5)).frame(width: 13, height: 13) }
            }
        }
        .chartYScale(domain: floor...(high + margin * 0.6))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(collisionResolution: .greedy).font(axisFont).foregroundStyle(Palette.inkSecondary)
            }
        }
        .chartYAxis { moneyAxis() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    // While the page scrolls, the chart moving under the pointer isn't a scrub.
                    .allowsHitTesting(!isScrolling)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !isScrolling, let plot = proxy.plotFrame else { return }
                            let x = location.x - geometry[plot].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            let day = nearest(to: date)
                            // Each change redraws the chart, so only a new day counts.
                            if day?.day != scrubbed?.day { scrubbed = day }
                        case .ended:
                            if scrubbed != nil { scrubbed = nil }
                        }
                    }
            }
        }
    }

    /// Chained goals are named by their amount ("$150K net worth"), which
    /// would pin the hidden axis to a known figure, so with amounts hidden
    /// the marker goes unnamed.
    /// Where a day falls across the drawn range, 0 at the start and 1 at the end.
    private func position(of day: Day) -> Double {
        guard let first = series.first?.day.startDate(in: .current), let last = series.last?.day.startDate(in: .current),
            last > first
        else { return 0 }
        return day.startDate(in: .current).timeIntervalSince(first) / last.timeIntervalSince(first)
    }

    /// Whether a marker's label sits under the line: where the line over the
    /// label's stretch is higher than the marker, under it is clear. Stays
    /// above near the bottom, clear of the axis.
    private func labelGoesBelow(_ marker: GoalMarker, value: Double, runsLeft: Bool, floor: Double, high: Double) -> Bool {
        guard (value - floor) / max(high - floor, 1) > 0.15,
            let index = series.firstIndex(where: { $0.day >= marker.day })
        else { return false }
        let reach = max(series.count / 5, 1)
        let along = series[runsLeft ? max(index - reach, 0) : min(index + reach, series.count - 1)].total.chartValue
        return along > value
    }

    private func markerLabel(_ marker: GoalMarker) -> String {
        amountsHidden ? "Reached a goal" : "Reached \(marker.name)"
    }

    private func nearest(to date: Date) -> DailyTotal? {
        let target = Day(date, in: .current)
        guard let first = exact.first else { return nil }
        let index = min(max(target.ordinal - first.day.ordinal, 0), exact.count - 1)
        return exact[index]
    }
}
