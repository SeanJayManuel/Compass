import Charts
import Core
import SwiftUI

/// How a line's measure reads. Its sign and which way is good live in Core.
extension BalanceHistoryMeasure {
    /// Under the chart, so a falling debt line reads as good news.
    var note: String? {
        self == .owed ? "Shown as what you owe, so lower is better." : nil
    }

    /// "$12,340", "$4,120 owed", or "$80 in credit" for an overpaid card.
    func label(_ value: Decimal) -> String {
        switch reading(value) {
        case .balance(let amount): amount.wholeDollars
        case .owed(let amount): "\(amount.wholeDollars) owed"
        case .inCredit(let amount): "\(amount.wholeDollars) in credit"
        }
    }
}

/// Small chart and icon type: 10 pt at Standard, scaled by the Settings text size.
enum AccountsSmallType {
    static var text: Font { .system(size: 10 * TextSize.current.scale) }
    static var icon: Font { .system(size: 10 * TextSize.current.scale, weight: .semibold) }
}

/// One range for every chart on the Accounts screen, so expanded cards agree.
enum AccountsHistoryRange {
    static let key = "accounts.range"
}

/// A class's or an account's own line over time: the range, a readout that
/// follows the pointer, and the chart.
struct BalanceHistoryPanel: View {
    /// Every day from the first balance through `today` (or the day an
    /// archived account stopped), already in the measure's sign.
    let series: [DailyTotal]
    let measure: BalanceHistoryMeasure
    let color: Color
    let today: Day
    var chartHeight: CGFloat = 180
    /// A line under the chart, after the measure's own note.
    var note: String?
    /// Shown instead of the chart when there's no history at all.
    let emptyMessage: String
    @AppStorage(AccountsHistoryRange.key) private var range = TimeRange.oneYear

    /// Long ranges draw the average of each stretch of days, as the Net Worth
    /// chart does, so a paycheck in or a card paid off doesn't read as the trend.
    private let pointLimit = 120

    var body: some View {
        // Ranges count back from the line's last day: today, or the day an
        // archived account stopped.
        let end = series.last.map { min($0.day, today) } ?? today
        let visible = NetWorthSeries.trim(series, to: range, endingOn: end)
        let notes = [measure.note, note].compactMap { $0 }
        VStack(alignment: .leading, spacing: Spacing.s) {
            if series.isEmpty {
                message(emptyMessage)
            } else {
                AccountsRangePicker(range: $range)
                if visible.count > 1 {
                    let drawn = NetWorthSeries.averaged(visible, toAtMost: pointLimit)
                    BalanceHistoryScrub(
                        visible: visible, drawn: drawn,
                        // Dates once per range, not once per mark on every hover.
                        points: drawn.map { ChartPoint(date: $0.day.startDate(in: .current), value: $0.total.chartValue) },
                        // The days whose values read widest, once per range.
                        widest: [visible.min { $0.total < $1.total }, visible.max { $0.total < $1.total }].compactMap { $0 },
                        today: today, measure: measure, color: color, chartHeight: chartHeight
                    )
                } else if series.count > 1 {
                    // YTD on Jan 1, say: the history is there, the range is short.
                    message("This range holds only one day. Pick a longer range to see a trend.")
                } else {
                    message("Only one day of history so far. Come back after a few more balances to see a trend.")
                }
            }
            if !notes.isEmpty {
                message(notes.joined(separator: " "))
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ChartPoint {
    var date: Date
    var value: Double
}

/// Holds the hover position, so moving the pointer re-renders only the
/// readout and the chart, never the cards around them.
private struct BalanceHistoryScrub: View {
    /// Every day in the range, contiguous, so a day finds its value by offset.
    let visible: [DailyTotal]
    let drawn: [DailyTotal]
    /// `drawn`, ready to plot.
    let points: [ChartPoint]
    /// The range's lowest and highest days, for the readout's layout.
    let widest: [DailyTotal]
    let today: Day
    let measure: BalanceHistoryMeasure
    let color: Color
    let chartHeight: CGFloat
    /// The hovered day rather than its value, so a reload under the pointer
    /// shows the new value.
    @State private var scrubbedDay: Day?

    var body: some View {
        let scrubbed = scrubbedDay.flatMap(exact(on:))
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let start = visible.first, let latest = visible.last {
                let shown = scrubbed ?? latest
                BalanceHistoryReadout(shown: shown, today: today, start: start, measure: measure, widest: widest)
            }
            BalanceHistoryChart(
                drawn: drawn, points: points, firstDay: visible.first?.day, dayCount: visible.count,
                color: color, scrubbed: scrubbed, scrubbedDay: $scrubbedDay
            )
            .frame(height: chartHeight)
        }
    }

    private func exact(on day: Day) -> DailyTotal? {
        guard let first = visible.first else { return nil }
        let index = day.ordinal - first.day.ordinal
        return visible.indices.contains(index) ? visible[index] : nil
    }
}

/// The value on the hovered day (or the last day) and how far it moved since
/// the range began. Text stays in ink; the change wears status colors with an arrow.
private struct BalanceHistoryReadout: View {
    let shown: DailyTotal
    let today: Day
    let start: DailyTotal
    let measure: BalanceHistoryMeasure
    /// The range's lowest and highest days: their values and changes read widest.
    let widest: [DailyTotal]

    /// Under half a dollar rounds to $0, which isn't a change worth a color.
    private static let halfDollar = Decimal(5) / 10

    /// "today" and a two-digit day in every month. Digits are monospaced, so
    /// one of these is as wide as any date the readout shows.
    private static let everyDateWidth: [String] =
        ["today"]
        + (1...12).map { month in
            formatted(Day(year: 2000, month: month, day: 28))
        }

    var body: some View {
        // One line or two is chosen for the widest day in the range, not the
        // one shown, so scrubbing never reflows it and the chart never jumps
        // out from under the pointer.
        ViewThatFits(in: .horizontal) {
            ZStack(alignment: .leading) {
                widestLine.hidden().accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    value
                    Spacer(minLength: Spacing.m)
                    change(shown)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                value
                change(shown)
            }
        }
    }

    /// The one-line readout at its widest: every value, date and change it
    /// can show in this range, stacked.
    private var widestLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                ZStack {
                    ForEach(widest.indices, id: \.self) { amount(widest[$0]) }
                }
                ZStack {
                    ForEach(Self.everyDateWidth, id: \.self) { dateText($0) }
                }
            }
            Spacer(minLength: Spacing.m)
            ZStack {
                ForEach(widest.indices, id: \.self) { change(widest[$0]) }
            }
        }
    }

    private var value: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            amount(shown)
            dateText(shown.day == today ? "today" : Self.formatted(shown.day))
        }
    }

    private func amount(_ point: DailyTotal) -> some View {
        Text(measure.label(point.total))
            .font(Typeface.body.weight(.semibold)).monospacedDigit()
            .foregroundStyle(Palette.ink)
            .privateAmount()
    }

    private func dateText(_ text: String) -> some View {
        Text(text).font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
    }

    private static func formatted(_ day: Day) -> String {
        day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private func change(_ point: DailyTotal) -> some View {
        // Linking an account isn't a change.
        let delta = point.withoutOpenings - start.withoutOpenings
        let since = "since \(Self.formatted(start.day))"
        if abs(delta) < Self.halfDollar {
            Text("No change \(since)").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        } else {
            let rising = delta > 0
            let good = measure.isGood(change: delta)
            let amount =
                switch measure {
                case .balance: delta.signedWholeDollars
                case .owed: abs(delta).wholeDollars
                }
            let label =
                switch measure {
                case .balance: since
                case .owed: rising ? "more owed \(since)" : "paid down \(since)"
                }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                    .font(AccountsSmallType.icon)
                    .foregroundStyle(good ? Palette.onPace : Palette.failure)
                    .accessibilityHidden(true)
                Text(amount).monospacedDigit()
                    .foregroundStyle(good ? Palette.onPace : Palette.failure)
                    .privateAmount()
                Text(label).foregroundStyle(Palette.inkSecondary)
            }
            .font(Typeface.detail)
            .accessibilityElement(children: .combine)
        }
    }
}

/// One series: a thin line in the class's color over a faint wash, an end dot,
/// and a crosshair that snaps to the day under the pointer.
private struct BalanceHistoryChart: View {
    @Environment(\.scrollActivity) private var scrollActivity
    private var isScrolling: Bool { scrollActivity?.isScrolling ?? false }
    /// What's drawn: averaged for long ranges.
    let drawn: [DailyTotal]
    /// `drawn`, ready to plot.
    let points: [ChartPoint]
    /// The range's first day and length, to snap the pointer to a day.
    let firstDay: Day?
    let dayCount: Int
    let color: Color
    /// The hovered day's exact value.
    let scrubbed: DailyTotal?
    @Binding var scrubbedDay: Day?
    @AppStorage(HideAmounts.key) private var amountsHidden = false

    var body: some View {
        let values = points.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        // A flat line still gets readable ticks around it.
        let margin = Swift.max((high - low) * 0.12, abs(high) * 0.02, 10)
        let floor = low - margin
        let top = high + margin * 0.6
        // Under $10K, ticks read as plain dollars; above, compact with enough
        // digits that ticks close together don't all say "$15K".
        let compact = Swift.max(abs(floor), abs(top)) >= 10_000
        Chart {
            ForEach(points, id: \.date) { point in
                // The soft fill runs from the bottom of the chart, not from zero.
                AreaMark(
                    x: .value("Day", point.date),
                    yStart: .value("Floor", floor), yEnd: .value("Balance", point.value)
                )
                .foregroundStyle(color.opacity(0.1))
                .interpolationMethod(.catmullRom)
                LineMark(x: .value("Day", point.date), y: .value("Balance", point.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
            }
            if let scrubbed {
                RuleMark(x: .value("Day", scrubbed.day.startDate(in: .current)))
                    .foregroundStyle(Palette.inkSecondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                // On the drawn line; the readout above shows the exact day.
                PointMark(
                    x: .value("Day", scrubbed.day.startDate(in: .current)),
                    y: .value("Balance", (NetWorthSeries.value(on: scrubbed.day, in: drawn) ?? scrubbed.total).chartValue)
                )
                .symbol { dot }
            } else if let last = points.last {
                PointMark(x: .value("Day", last.date), y: .value("Balance", last.value))
                    .symbol { dot }
            }
        }
        .chartYScale(domain: floor...top)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel().font(AccountsSmallType.text).foregroundStyle(Palette.inkSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Palette.rule)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(
                            compact
                                ? amount.formatted(.currency(code: "USD").notation(.compactName).precision(.significantDigits(1...3)))
                                : amount.formatted(.currency(code: "USD").precision(.fractionLength(0)))
                        )
                        .font(AccountsSmallType.text).monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                        .privateAmount()
                    }
                }
            }
        }
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
                            if day != scrubbedDay { scrubbedDay = day }
                        case .ended:
                            if scrubbedDay != nil { scrubbedDay = nil }
                        }
                    }
            }
        }
        // The marks carry values for VoiceOver; hidden amounts hide them too.
        .accessibilityHidden(amountsHidden)
    }

    /// An 8 pt dot in the series color with a 2 pt ring in the card's surface.
    private var dot: some View {
        Circle().fill(color).overlay(Circle().strokeBorder(Palette.surface, lineWidth: 2)).frame(width: 12, height: 12)
    }

    /// The day under the pointer, clamped to the range.
    private func nearest(to date: Date) -> Day? {
        guard let firstDay, dayCount > 0 else { return nil }
        let offset = min(max(Day(date, in: .current).ordinal - firstDay.ordinal, 0), dayCount - 1)
        return Day(ordinal: firstDay.ordinal + offset)
    }
}

private struct AccountsRangePicker: View {
    @Binding var range: TimeRange

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(TimeRange.allCases, id: \.self) { option in
                Button(option.rawValue) {
                    withAnimation(Motion.change) { range = option }
                }
                .buttonStyle(RangeButtonStyle(selected: option == range))
                .accessibilityAddTraits(option == range ? .isSelected : [])
            }
        }
    }
}
