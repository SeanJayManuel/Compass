import Foundation

/// The time range every chart shares.
public enum TimeRange: String, CaseIterable, Sendable {
    case threeMonths = "3M"
    case sixMonths = "6M"
    case yearToDate = "YTD"
    case oneYear = "1Y"
    case fiveYears = "5Y"
    case all = "All"

    /// The first day in this range when it ends on `end`, or nil for all time.
    public func start(endingOn end: Day) -> Day? {
        switch self {
        case .threeMonths: end.addingMonths(-3)
        case .sixMonths: end.addingMonths(-6)
        case .yearToDate: Day(year: end.year, month: 1, day: 1)
        case .oneYear: end.addingMonths(-12)
        case .fiveYears: end.addingMonths(-60)
        case .all: nil
        }
    }
}

extension NetWorthSeries {
    public static func trim(_ series: [DailyTotal], to range: TimeRange, endingOn end: Day) -> [DailyTotal] {
        guard let start = range.start(endingOn: end) else { return series.filter { $0.day <= end } }
        return series.filter { $0.day >= start && $0.day <= end }
    }

    /// How much the last total differs from the total on `day`, or from the
    /// first total when the series starts after `day`. Opening balances of
    /// accounts linked in between aren't a change.
    public static func change(in series: [DailyTotal], since day: Day) -> Decimal? {
        guard let last = series.last else { return nil }
        let base = series.last(where: { $0.day <= day }) ?? series.first!
        return last.withoutOpenings - base.withoutOpenings
    }
}

extension NetWorthSeries {
    /// How much net worth moved in each month: the month's last total minus
    /// the previous month's last total (or the first total, for the first
    /// month), leaving out opening balances.
    /// Monthly changes for a range starting on `start`: computed on the whole
    /// series, keeping only months that start on or after `start`, so no bar
    /// covers part of a month.
    public static func monthlyChange(_ series: [DailyTotal], from start: Day?) -> [MonthTotal] {
        let changes = monthlyChange(series)
        guard let start else { return changes }
        return changes.filter { Day(year: $0.month.year, month: $0.month.month, day: 1) >= start }
    }

    public static func monthlyChange(_ series: [DailyTotal]) -> [MonthTotal] {
        guard let first = series.first else { return [] }
        var lastByMonth: [(Month, Decimal)] = []
        for point in series {
            let month = Month(point.day)
            if lastByMonth.last?.0 == month {
                lastByMonth[lastByMonth.count - 1].1 = point.withoutOpenings
            } else {
                lastByMonth.append((month, point.withoutOpenings))
            }
        }
        var previous = first.withoutOpenings
        return lastByMonth.map { month, total in
            defer { previous = total }
            return MonthTotal(month: month, total: total - previous)
        }
    }

    /// Evenly spaced points, always keeping the first and last, so a long
    /// range draws about one point per pixel.
    public static func downsample<Point>(_ series: [Point], toAtMost limit: Int) -> [Point] {
        guard series.count > limit, limit >= 2 else { return series }
        let step = Double(series.count - 1) / Double(limit - 1)
        return (0..<limit).map { series[Int((Double($0) * step).rounded())] }
    }
}

public struct ClassShare: Hashable, Sendable {
    public var accountClass: AccountClass
    public var amount: Decimal
    /// Of all positive classes, 0 to 1.
    public var share: Decimal

    public init(accountClass: AccountClass, amount: Decimal, share: Decimal) {
        self.accountClass = accountClass
        self.amount = amount
        self.share = share
    }
}

extension NetWorthSeries {
    /// Where the assets sit on one day: each class with a positive total and
    /// its share of all of them. Debts aren't an allocation.
    public static func allocation(_ day: DailyBreakdown) -> [ClassShare] {
        let parts = AccountClass.allCases.compactMap { accountClass -> (AccountClass, Decimal)? in
            guard let amount = day.byClass[accountClass], amount > 0 else { return nil }
            return (accountClass, amount)
        }
        let assets = parts.reduce(Decimal(0)) { $0 + $1.1 }
        return parts.map { ClassShare(accountClass: $0.0, amount: $0.1, share: $0.1 / assets) }
    }
}

extension NetWorthSeries {
    /// The drawn value on `day`: straight-line between the averaged points
    /// around it, so a dot placed on the chart sits on the line.
    public static func value(on day: Day, in drawn: [DailyTotal]) -> Decimal? {
        guard let first = drawn.first, let last = drawn.last else { return nil }
        if day <= first.day { return first.total }
        if day >= last.day { return last.total }
        guard let upper = drawn.firstIndex(where: { $0.day >= day }), upper > 0 else { return first.total }
        let a = drawn[upper - 1], b = drawn[upper]
        let span = Decimal(b.day.ordinal - a.day.ordinal)
        return span == 0 ? b.total : a.total + (b.total - a.total) * Decimal(day.ordinal - a.day.ordinal) / span
    }

    /// For drawing a long range: each stretch of days becomes its average,
    /// dated at the stretch's first day, so day-to-day noise doesn't read as
    /// the trend. The last point stays exact, since it's today's value.
    public static func averaged(_ series: [DailyTotal], toAtMost limit: Int) -> [DailyTotal] {
        buckets(series.count, limit).map { range in
            DailyTotal(
                day: series[range.lowerBound].day, total: series[range].reduce(0) { $0 + $1.total } / Decimal(range.count),
                opened: series[range].reduce(0) { $0 + $1.opened } / Decimal(range.count))
        } + (series.count > limit ? [series[series.count - 1]] : [])
    }

    public static func averaged(_ series: [DailyBreakdown], toAtMost limit: Int) -> [DailyBreakdown] {
        buckets(series.count, limit).map { range in
            let points = series[range]
            let count = Decimal(range.count)
            var byClass: [AccountClass: Decimal] = [:], opened: [AccountClass: Decimal] = [:]
            for point in points {
                for (accountClass, amount) in point.byClass { byClass[accountClass, default: 0] += amount }
                for (accountClass, amount) in point.openedByClass { opened[accountClass, default: 0] += amount }
            }
            return DailyBreakdown(
                day: series[range.lowerBound].day,
                total: points.reduce(0) { $0 + $1.total } / count,
                accessible: points.reduce(0) { $0 + $1.accessible } / count,
                byClass: byClass.mapValues { $0 / count },
                openedByClass: opened.mapValues { $0 / count }
            )
        } + (series.count > limit ? [series[series.count - 1]] : [])
    }

    /// Splits `count` points into at most `limit - 1` even stretches (the
    /// last point is added back exact), or one point each when it fits.
    private static func buckets(_ count: Int, _ limit: Int) -> [Range<Int>] {
        guard count > limit, limit >= 2 else { return (0..<count).map { $0..<($0 + 1) } }
        let stretches = limit - 1
        let body = count - 1
        return (0..<stretches).map { index in
            (index * body / stretches)..<((index + 1) * body / stretches)
        }.filter { !$0.isEmpty }
    }
}
