import Charts
import Core
import SwiftUI

/// A goal's measured value over time, with its target, its minimum if it's a
/// range, its target date, and the current pace carried forward to the target.
struct GoalHistoryChart: View {
    /// What's drawn: already trimmed to the range and averaged.
    let series: [DailyTotal]
    let goal: Goal
    let progress: GoalProgress
    let today: Day
    @AppStorage(HideAmounts.key) private var amountsHidden = false

    private static let projectionSeries = "Projection"

    var body: some View {
        let reading = GoalReading(goal: goal, progress: progress, today: today)
        // A goal already reached has nothing left to project.
        let projection = reading.isReached ? nil : progress.projectionLine(today: today)
        let start = series.first?.day ?? today
        let end = domainEnd(projection: projection)
        let range = valueRange(projection: projection)
        Chart {
            ForEach(series, id: \.day) { point in
                // The soft fill runs from the bottom of the chart, not from zero.
                AreaMark(
                    x: .value("Day", point.day.startDate(in: .current)),
                    yStart: .value("Floor", range.floor), yEnd: .value("Value", point.total.chartValue),
                    series: .value("Series", "History")
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Palette.ink.opacity(0.14), Palette.ink.opacity(0)],
                        startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.catmullRom)
                LineMark(
                    x: .value("Day", point.day.startDate(in: .current)), y: .value("Value", point.total.chartValue),
                    series: .value("Series", "History")
                )
                .foregroundStyle(Palette.ink)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
            if let minimum = goal.targetMin, progress.target > minimum {
                RuleMark(y: .value("Minimum", minimum.chartValue))
                    .foregroundStyle(Palette.inkSecondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Minimum").font(Typeface.caption).foregroundStyle(Palette.inkSecondary)
                    }
            }
            RuleMark(y: .value("Target", progress.target.chartValue))
                .foregroundStyle(Palette.inkSecondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                    Text("Target \(GoalLifecycle.compactDollars(progress.target))")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).privateAmount()
                }
            // No label of its own: it would land on the time axis's last tick at
            // narrow widths. The caption under the chart names it.
            if let date = goal.targetDate, Self.drawsTargetDate(goal: goal, progress: progress, today: today, start: start) {
                RuleMark(x: .value("Target date", date.startDate(in: .current)))
                    .foregroundStyle(Palette.inkSecondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if let projection {
                ForEach(projection, id: \.day) { point in
                    LineMark(
                        x: .value("Day", point.day.startDate(in: .current)), y: .value("Value", point.total.chartValue),
                        series: .value("Series", Self.projectionSeries)
                    )
                    .foregroundStyle(Palette.ink.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 5]))
                }
            }
            if let reached = reading.achieved, reached.day >= start {
                let onLine = (NetWorthSeries.value(on: reached.day, in: series) ?? reached.value).chartValue
                PointMark(x: .value("Day", reached.day.startDate(in: .current)), y: .value("Value", onLine))
                    .symbol { Circle().strokeBorder(Palette.onPace, lineWidth: 2).background(Circle().fill(Palette.surface)).frame(width: 11, height: 11) }
                    // No label of its own. Charts drew one about 55 pt above and 40 pt left of
                    // the marker, even with an explicit anchor, size and overflow rule. The
                    // header status and the figure line under it already say when it was reached.
                    .accessibilityLabel("Reached on \(reached.day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted))")
            }
            if let last = series.last {
                PointMark(x: .value("Day", last.day.startDate(in: .current)), y: .value("Value", last.total.chartValue))
                    .symbol { Circle().fill(Palette.ink).overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2.5)).frame(width: 13, height: 13) }
            }
        }
        .chartXScale(domain: start.startDate(in: .current)...max(end, start).startDate(in: .current))
        .chartYScale(domain: range.floor...range.ceiling)
        .chartXAxis { timeAxis() }
        .chartYAxis { moneyAxis() }
        .accessibilityLabel(summary)
    }

    /// The chart runs to today, the projected day, and the target date when it's near.
    private func domainEnd(projection: [DailyTotal]?) -> Day {
        Self.domainEnd(goal: goal, today: today, projection: projection)
    }

    private static func domainEnd(goal: Goal, today: Day, projection: [DailyTotal]?) -> Day {
        var end = today
        if let last = projection?.last?.day { end = max(end, last) }
        if let date = goal.targetDate, date <= today.addingMonths(60) { end = max(end, date) }
        return end
    }

    /// Whether the target date's line is drawn: the goal isn't reached, and
    /// the date falls inside the days the chart shows (from `start`).
    static func drawsTargetDate(goal: Goal, progress: GoalProgress, today: Day, start: Day) -> Bool {
        guard let date = goal.targetDate,
            !GoalReading(goal: goal, progress: progress, today: today).isReached
        else { return false }
        return date >= start && date <= domainEnd(goal: goal, today: today, projection: progress.projectionLine(today: today))
    }

    /// The value axis holds the line, the target and the projection, with
    /// room above for the target's label.
    private func valueRange(projection: [DailyTotal]?) -> (floor: Double, ceiling: Double) {
        var values = series.map(\.total.chartValue) + [progress.target.chartValue]
        if let minimum = goal.targetMin { values.append(minimum.chartValue) }
        values += projection?.map(\.total.chartValue) ?? []
        let low = values.min() ?? 0, high = values.max() ?? 1
        let margin = max((high - low) * 0.12, 1)
        // A goal that has never been below $0 never draws below it either.
        let floor = low >= 0 ? max(low - margin, 0) : low - margin
        return (floor, high + margin * 1.4)
    }

    private var summary: String {
        guard !amountsHidden, let first = series.first, let last = series.last else { return "Goal history chart" }
        return "From \(first.total.wholeDollars) to \(last.total.wholeDollars) over the range; target \(progress.target.wholeDollars)"
    }
}
