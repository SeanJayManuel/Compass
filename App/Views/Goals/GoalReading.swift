import Core
import Foundation
import SwiftUI

/// How one goal reads on the list and on its page: its standing in words,
/// what it measures, and its figures as text. Presentation only; every
/// number comes from `GoalProgress`.
struct GoalReading {
    let goal: Goal
    let progress: GoalProgress
    let today: Day

    var achieved: (day: Day, value: Decimal)? {
        if case .achieved(let day, let value) = goal.status { return (day, value) }
        return nil
    }

    var isFIRE: Bool {
        if case .fire = goal.kind { return true }
        return false
    }

    /// Done, whether the goal was marked achieved or has just hit its target.
    var isReached: Bool { achieved != nil || progress.standing == .reached }

    // MARK: The bar

    /// 0 to 1. A goal that was reached stays full, whatever its balance does later.
    var barFraction: Double { isReached ? 1 : progress.fraction.chartValue }

    /// Where a range's minimum sits on the bar.
    var minimumTick: Double? {
        guard let minimum = goal.targetMin, progress.target > 0, minimum < progress.target else { return nil }
        return (minimum / progress.target).chartValue
    }

    /// Whole percent, rounded down so 99.9% never reads as reached.
    var percent: Int {
        if isReached { return 100 }
        var scaled = progress.fraction * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .down)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    // MARK: Standing

    var status: (text: String, symbol: String, tone: StatusTone) {
        if let achieved {
            return ("Reached \(achieved.day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted))", "checkmark", .good)
        }
        switch progress.reading(dated: goal.targetDate != nil) {
        case .reached: return ("Reached", "checkmark", .good)
        case .onTrack: return ("On track", "checkmark", .good)
        case .behind: return ("Behind", "exclamationmark.triangle", .attention)
        case .growing: return ("Growing", "arrow.up.right", .neutral)
        case .notGrowing: return ("Not growing", "minus", .attention)
        }
    }

    /// The 3-month pace is above zero.
    private var growing: Bool { (progress.pacePerMonth ?? 0) > 0 }

    // MARK: List columns

    /// "$1,470/mo", or nil when the goal has no date to need it by.
    var needsPerMonth: String? {
        guard !isReached, let needed = progress.neededPerMonth else { return nil }
        return "\(needed.wholeDollars)/mo"
    }

    /// "$2,159/mo", "Not growing", or nil when there isn't history to say.
    var pacePerMonth: String? {
        guard !isReached, let pace = progress.pacePerMonth else { return nil }
        return pace > 0 ? "\(pace.wholeDollars)/mo" : "Not growing"
    }

    /// "Oct 2027", "~95 yrs", "100+ yrs" (growing, but past the projection cap),
    /// "Reached", or "—".
    var getsThere: String {
        if isReached { return "Reached" }
        guard let projected = progress.projectedDate else { return growing ? "100+ yrs" : "—" }
        if isFIRE, daysAway(projected) > 730 { return "~\(years(projected)) yrs" }
        return projected.startDate(in: .current).formatted(.dateTime.month(.abbreviated).year())
    }

    /// "target Apr 2028", under the projection.
    var targetNote: String? {
        guard !isReached, let date = goal.targetDate else { return nil }
        return "target \(date.startDate(in: .current).formatted(.dateTime.month(.abbreviated).year()))"
    }

    /// The compact row's one line: "Needs $1,470/mo · Pace $2,159/mo · Oct 2027 · target Apr 2028".
    var compactLine: String? {
        guard !isReached else { return nil }
        var parts: [String] = []
        if let needs = needsPerMonth { parts.append("Needs \(needs)") }
        if let pace = pacePerMonth { parts.append(pace == "Not growing" ? pace : "Pace \(pace)") }
        if getsThere != "—" { parts.append(getsThere) }
        // Non-breaking spaces keep "target Apr 2028" together when the line wraps.
        if let note = targetNote { parts.append(note.replacingOccurrences(of: " ", with: "\u{00A0}")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: What VoiceOver says for the list's figure cells
    // The column header is hidden from VoiceOver, so each cell names its own column.

    var needsLabel: String {
        // A reached goal needs nothing more; say so rather than "no target date".
        if isReached { return "Needs: nothing more" }
        guard let needed = progress.neededPerMonth else { return "Needs: no target date" }
        return "Needs \(needed.wholeDollars) a month"
    }

    var paceLabel: String {
        if isReached { return "Pace: not shown, the goal is reached" }
        guard let pace = progress.pacePerMonth else { return "Pace: not enough history yet" }
        if progress.paceFromContributions {
            return pace > 0 ? "Putting in \(pace.wholeDollars) a month" : "Pace: nothing put in lately"
        }
        return pace > 0 ? "Pace \(pace.wholeDollars) a month" : "Pace: not growing"
    }

    var getsThereLabel: String {
        var label: String
        if isReached {
            label = "Reached"
        } else if let projected = progress.projectedDate {
            label = isFIRE && daysAway(projected) > 730 ? "Gets there in about \(years(projected)) years" : "Gets there \(monthYear(projected))"
        } else {
            label = growing ? "Gets there in more than 100 years" : "Gets there: no projected date"
        }
        if let date = goal.targetDate, !isReached { label += ", target \(monthYear(date))" }
        return label
    }

    // MARK: The page

    /// "of $175,000 · $26,443 to go", or the range's two stages.
    var toGoLine: String {
        if let achieved {
            return "Reached \(achieved.day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted)) at \(achieved.value.wholeDollars)"
        }
        if progress.standing == .reached { return "Target reached" }
        if let minimum = goal.targetMin {
            return progress.minimumReached
                ? "Minimum \(minimum.wholeDollars) reached · \(progress.remaining.wholeDollars) to \(progress.target.wholeDollars)"
                : "\(max(minimum - progress.current, 0).wholeDollars) to the minimum · \(progress.remaining.wholeDollars) to target"
        }
        return "of \(progress.target.wholeDollars) · \(progress.remaining.wholeDollars) to go"
    }

    /// The big figure: where the goal stands, or the amount it reached.
    var figure: Decimal { achieved?.value ?? progress.current }

    var needsSentence: String? {
        guard !isReached, let needed = progress.neededPerMonth, let date = goal.targetDate else { return nil }
        return "\(needed.wholeDollars) a month to reach it by \(monthYear(date))"
    }

    var paceSentence: String? {
        guard !isReached, let pace = progress.pacePerMonth else { return nil }
        if progress.paceFromContributions {
            // An invested goal's pace is what they put in; the market's part is shown apart.
            var sentence = "\(pace.wholeDollars) a month put in over the last 3 full months"
            if let market = progress.marketPerMonth, abs(market) >= 1 {
                sentence += ", and the market \(market > 0 ? "added" : "took") \(abs(market).wholeDollars) a month"
            }
            return sentence
        }
        return pace > 0 ? "\(pace.wholeDollars) a month over the last 3 months" : "Not growing over the last 3 months"
    }

    /// Nil once reached: there's nowhere left to get to.
    var getsThereSentence: String? {
        if isReached { return nil }
        guard let projected = progress.projectedDate else {
            guard let pace = progress.pacePerMonth else { return "Not enough history for a projected date yet." }
            return pace > 0
                ? "More than 100 years at this pace."
                : "Not growing over the last 3 months, so there's no projected date yet."
        }
        if isFIRE, daysAway(projected) > 730 { return "About \(years(projected)) years at this pace" }
        return monthYear(projected)
    }

    /// "$40,000 × 25" for a financial independence goal.
    var spendingSentence: String? {
        guard case .fire(let spending, let multiplier) = goal.kind else { return nil }
        return "\(spending.wholeDollars) × \(multiplier.formatted(.number))"
    }

    // MARK: What it measures

    /// "Net worth", the account's name or "3 accounts", or "Investable · 25 × $40,000".
    func measure(accountNames: [UUID: String]) -> String {
        switch goal.kind {
        case .netWorth:
            return "Net worth"
        case .accountTotal(let ids):
            if ids.count == 1, let name = ids.first.flatMap({ accountNames[$0] }) { return name }
            return ids.count == 1 ? "1 account" : "\(ids.count) accounts"
        case .fire(let spending, let multiplier):
            return "Investable · \(multiplier.formatted(.number)) × \(spending.wholeDollars)"
        }
    }

    // MARK: Dates

    private func daysAway(_ day: Day) -> Int { day.ordinal - today.ordinal }

    private func years(_ day: Day) -> Int { Int((Double(daysAway(day)) / 365.25).rounded()) }

    private func monthYear(_ day: Day) -> String {
        day.startDate(in: .current).formatted(.dateTime.month(.wide).year())
    }
}
