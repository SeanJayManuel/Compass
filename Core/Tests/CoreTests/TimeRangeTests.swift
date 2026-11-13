import Core
import Foundation
import Testing

@Suite struct TimeRangeTests {
    let today = Day(year: 2026, month: 10, day: 20)

    @Test(arguments: [
        (TimeRange.threeMonths, Day(year: 2026, month: 7, day: 20)),
        (.sixMonths, Day(year: 2026, month: 4, day: 20)),
        (.yearToDate, Day(year: 2026, month: 1, day: 1)),
        (.oneYear, Day(year: 2025, month: 10, day: 20)),
        (.fiveYears, Day(year: 2021, month: 10, day: 20))
    ])
    func eachRangeStartsOnTheExpectedDay(range: TimeRange, start: Day) {
        #expect(range.start(endingOn: today) == start)
    }

    @Test func allTimeHasNoStart() {
        #expect(TimeRange.all.start(endingOn: today) == nil)
    }

    @Test func aSeriesTrimmedToARangeKeepsOnlyThoseDays() {
        let series = (0..<200).map { DailyTotal(day: Day(ordinal: today.ordinal - 199 + $0), total: Decimal($0)) }
        let trimmed = NetWorthSeries.trim(series, to: .threeMonths, endingOn: today)
        #expect(trimmed.first?.day == Day(year: 2026, month: 7, day: 20))
        #expect(trimmed.last?.day == today)
    }

    @Test func changeSinceADayComparesTodayWithThatDay() {
        let series = [
            DailyTotal(day: Day(year: 2026, month: 9, day: 19), total: 900),
            DailyTotal(day: Day(year: 2026, month: 9, day: 20), total: 1000),
            DailyTotal(day: Day(year: 2026, month: 10, day: 20), total: 1250)
        ]
        #expect(NetWorthSeries.change(in: series, since: Day(year: 2026, month: 9, day: 20)) == 250)
    }

    @Test func changeSinceBeforeTheFirstDayMeasuresFromTheFirstDay() {
        let series = [
            DailyTotal(day: Day(year: 2026, month: 10, day: 1), total: 1000),
            DailyTotal(day: Day(year: 2026, month: 10, day: 20), total: 1100)
        ]
        #expect(NetWorthSeries.change(in: series, since: Day(year: 2026, month: 1, day: 1)) == 100)
    }

    @Test func noChangeForAnEmptySeries() {
        #expect(NetWorthSeries.change(in: [], since: today) == nil)
    }

    @Test func monthlyChangeComparesEachMonthsLastDayWithTheMonthBefore() {
        let series = [
            DailyTotal(day: Day(year: 2026, month: 8, day: 20), total: 1000),
            DailyTotal(day: Day(year: 2026, month: 8, day: 31), total: 1100),
            DailyTotal(day: Day(year: 2026, month: 9, day: 30), total: 1050),
            DailyTotal(day: Day(year: 2026, month: 10, day: 20), total: 1300)
        ]
        #expect(
            NetWorthSeries.monthlyChange(series) == [
                MonthTotal(month: Month(year: 2026, month: 8), total: 100),
                MonthTotal(month: Month(year: 2026, month: 9), total: -50),
                MonthTotal(month: Month(year: 2026, month: 10), total: 250)
            ])
    }

    @Test func downsamplingKeepsTheEndsAndStaysUnderTheLimit() {
        let series = (0..<3650).map { DailyTotal(day: Day(ordinal: $0), total: Decimal($0)) }
        let thinned = NetWorthSeries.downsample(series, toAtMost: 500)
        #expect(thinned.count <= 500)
        #expect(thinned.first == series.first)
        #expect(thinned.last == series.last)
    }

    @Test func aShortSeriesIsLeftAlone() {
        let series = (0..<100).map { DailyTotal(day: Day(ordinal: $0), total: Decimal($0)) }
        #expect(NetWorthSeries.downsample(series, toAtMost: 500) == series)
    }

    @Test func monthlyChangeInARangeShowsOnlyWholeMonths() {
        let series = (0..<120).map { DailyTotal(day: Day(ordinal: Day(year: 2026, month: 6, day: 1).ordinal + $0), total: Decimal($0)) }
        // Starting Jul 20, July is partial, so the first bar is August (Jul 31 → Aug 31: +31).
        let changes = NetWorthSeries.monthlyChange(series, from: Day(year: 2026, month: 7, day: 20))
        #expect(changes.first == MonthTotal(month: Month(year: 2026, month: 8), total: 31))
    }

    @Test func allocationSharesCountOnlyPositiveClasses() {
        let day = DailyBreakdown(
            day: today, total: 800, accessible: 800,
            byClass: [.cash: 250, .taxable: 750, .debt: -200])
        let shares = NetWorthSeries.allocation(day)
        #expect(
            shares == [
                ClassShare(accountClass: .cash, amount: 250, share: Decimal(string: "0.25")!),
                ClassShare(accountClass: .taxable, amount: 750, share: Decimal(string: "0.75")!)
            ])
    }

    @Test func averagingAverageseachStretchAndKeepsTodayExact() {
        // 0, 10, 0, 10, ... over 401 days: 100 stretches of 4 days plus today, so the noise flattens to 5.
        let series = (0..<401).map { DailyTotal(day: Day(ordinal: $0), total: Decimal(($0 % 2) * 10)) }
        let smoothed = NetWorthSeries.averaged(series, toAtMost: 101)
        #expect(smoothed.count == 101)
        #expect(smoothed.dropLast().allSatisfy { $0.total == 5 })
        #expect(smoothed.last == series.last)
        #expect(smoothed.first?.day == series.first?.day)
    }

    @Test func averagingLeavesAShortSeriesAlone() {
        let series = (0..<90).map { DailyTotal(day: Day(ordinal: $0), total: Decimal($0)) }
        #expect(NetWorthSeries.averaged(series, toAtMost: 120) == series)
    }

    @Test func averagingABreakdownAveragesEveryClass() {
        let series = (0..<401).map {
            DailyBreakdown(
                day: Day(ordinal: $0), total: Decimal(($0 % 2) * 10),
                accessible: Decimal(($0 % 2) * 4), byClass: [.cash: Decimal(($0 % 2) * 10)])
        }
        let smoothed = NetWorthSeries.averaged(series, toAtMost: 101)
        #expect(smoothed.dropLast().allSatisfy { $0.total == 5 && $0.accessible == 2 && $0.byClass[.cash] == 5 })
        #expect(smoothed.last == series.last)
    }

    @Test func aDayBetweenDrawnPointsSitsOnTheLineBetweenThem() {
        let drawn = [DailyTotal(day: Day(ordinal: 0), total: 100), DailyTotal(day: Day(ordinal: 10), total: 200)]
        #expect(NetWorthSeries.value(on: Day(ordinal: 4), in: drawn) == 140)
        #expect(NetWorthSeries.value(on: Day(ordinal: 10), in: drawn) == 200)
        #expect(NetWorthSeries.value(on: Day(ordinal: 20), in: drawn) == 200)
    }
}
