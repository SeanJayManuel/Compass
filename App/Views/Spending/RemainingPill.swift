import Core
import SwiftUI

/// What's left on a line, in words, so the colour is never the only signal.
enum Remaining: Equatable {
    case income(planned: Decimal?, actual: Decimal)
    /// Income in total: what's still to come, line by line, and how far
    /// lines went past their plans.
    case incomes(planned: Decimal, outstanding: Decimal, extra: Decimal)
    case bill(planned: Decimal?, actual: Decimal)
    /// Fixed bills in total: what's still to pay, line by line, so an
    /// overpaid bill never covers an unpaid one, and how far bills went over.
    case bills(planned: Decimal, outstanding: Decimal, over: Decimal)
    case spending(budget: Decimal, actual: Decimal)
    /// Money put into a savings account against its plan, and all of them.
    case saving(planned: Decimal?, actual: Decimal)
    case saved(planned: Decimal, outstanding: Decimal, extra: Decimal)

    enum Tone { case neutral, good, over }

    /// Nil when nothing was planned: an unbudgeted line has nothing to remain.
    /// Compared in whole dollars, as shown: a bill paid within a dollar of
    /// its plan is paid, never "$0 over" or "$0 left". Green is done, red
    /// is over, and what's still to come or to pay is neutral.
    var label: (text: String, tone: Tone)? {
        switch self {
        case .income(let planned, let actual):
            guard let planned, planned > 0 else { return nil }
            let extra = Self.dollars(actual - planned)
            if extra > 0 { return ("\(extra.wholeDollars) extra", .good) }
            if extra == 0 { return ("All in", .good) }
            return ("\((-extra).wholeDollars) to come", .neutral)
        case .bill(let planned, let actual):
            guard let planned, planned > 0 else { return nil }
            if actual == 0 { return ("\(planned.wholeDollars) due", .neutral) }
            let over = Self.dollars(actual - planned)
            if over > 0 { return ("\(over.wholeDollars) over", .over) }
            if over == 0 { return ("Paid", .good) }
            return ("\((-over).wholeDollars) left", .neutral)
        case .incomes(let planned, let outstanding, let extra):
            guard planned > 0 else { return nil }
            if Self.dollars(outstanding) > 0 { return ("\(outstanding.wholeDollars) to come", .neutral) }
            if Self.dollars(extra) > 0 { return ("\(extra.wholeDollars) extra", .good) }
            return ("All in", .good)
        case .bills(let planned, let outstanding, let over):
            guard planned > 0 else { return nil }
            if Self.dollars(outstanding) > 0 { return ("\(outstanding.wholeDollars) to pay", .neutral) }
            if Self.dollars(over) > 0 { return ("\(over.wholeDollars) over", .over) }
            return ("All paid", .good)
        case .saving(let planned, let actual):
            guard let planned, planned > 0 else { return nil }
            let extra = Self.dollars(actual - planned)
            if extra > 0 { return ("\(extra.wholeDollars) extra", .good) }
            if extra == 0 { return ("Saved", .good) }
            return ("\((-extra).wholeDollars) to go", .neutral)
        case .saved(let planned, let outstanding, let extra):
            guard planned > 0 else { return nil }
            if Self.dollars(outstanding) > 0 { return ("\(outstanding.wholeDollars) to go", .neutral) }
            if Self.dollars(extra) > 0 { return ("\(extra.wholeDollars) extra", .good) }
            return ("All saved", .good)
        case .spending(let budget, let actual):
            guard budget > 0 else { return nil }
            let over = Self.dollars(actual - budget)
            if over > 0 { return ("\(over.wholeDollars) over", .over) }
            return ("\((-over).wholeDollars) left", .neutral)
        }
    }

    /// An amount to the dollar, as the pill shows it.
    private static func dollars(_ amount: Decimal) -> Decimal {
        var amount = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &amount, 0, .plain)
        return rounded
    }
}

struct RemainingPill: View {
    let remaining: Remaining

    var body: some View {
        if let label = remaining.label {
            let color =
                switch label.tone {
                case .neutral: Palette.inkSecondary
                case .good: Palette.onPace
                case .over: Palette.failure
                }
            Text(label.text)
                .font(Typeface.detail.weight(.medium)).monospacedDigit()
                .foregroundStyle(label.tone == .neutral ? Palette.ink : color)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, Spacing.s).padding(.vertical, 3)
                // A light tint: green text on a 14% tint of itself is 4.2:1 in light mode;
                // on 7% it is 4.6:1 (red is 5.8:1, and both read better in dark mode).
                .background(Capsule().fill(label.tone == .neutral ? Palette.rule.opacity(0.7) : color.opacity(0.07)))
                .privateAmount()
        } else {
            // Holds the column, so a line with nothing remaining keeps the
            // others in place.
            Color.clear.frame(height: 1)
        }
    }
}
