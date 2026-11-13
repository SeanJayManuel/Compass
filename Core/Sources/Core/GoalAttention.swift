import Foundation

/// Which goal needs a look first.
public enum GoalAttention {
    /// Active goals in the order they need attention: behind a date first,
    /// then not growing, then on track by nearest target date, then undated
    /// by nearest projection (none last). Ties by name. Goals with no
    /// progress yet go last. Achieved and retired goals are left out. An
    /// active goal already at its target counts as on track. An undated goal
    /// that is growing but has no projected date (the projection stops at
    /// 1,200 months) is undated and last in its band, not "not growing".
    public static func order(_ goals: [Goal], progress: [UUID: GoalProgress]) -> [Goal] {
        goals
            .filter { $0.status == .active }
            .map { goal in (goal: goal, key: Key(goal, progress[goal.id])) }
            .sorted { a, b in
                if a.key != b.key { return a.key < b.key }
                let byName = a.goal.name.localizedCaseInsensitiveCompare(b.goal.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return a.goal.id.uuidString < b.goal.id.uuidString
            }
            .map(\.goal)
    }

    /// Where a goal sits: its band, then the day that ranks it within the band.
    private struct Key: Comparable {
        enum Band: Int { case behindADate, notGrowing, onTrackDated, onTrackUndated, notMeasured }

        var band: Band
        /// Nearest first; a goal with no day goes after the ones that have one.
        var day: Int

        init(_ goal: Goal, _ progress: GoalProgress?) {
            guard let progress else {
                band = .notMeasured
                day = Int.max
                return
            }
            switch (progress.standing, goal.targetDate) {
            case (.behind, .some):
                band = .behindADate
                day = 0
            case (.behind, .none):
                // No date to miss. Behind only because nothing reaches the target
                // within the projection cap: with a positive pace it is still
                // growing, so it ranks with the undated goals, furthest last.
                if (progress.pacePerMonth ?? 0) > 0 {
                    band = .onTrackUndated
                    day = Int.max
                } else {
                    band = .notGrowing
                    day = 0
                }
            case (_, .some(let date)):
                band = .onTrackDated
                day = date.ordinal
            case (_, .none):
                band = .onTrackUndated
                day = progress.projectedDate?.ordinal ?? Int.max
            }
        }

        static func < (a: Key, b: Key) -> Bool {
            (a.band.rawValue, a.day) < (b.band.rawValue, b.day)
        }
    }
}
