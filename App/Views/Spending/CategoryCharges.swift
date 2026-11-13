import Core
import SwiftData
import SwiftUI

/// The individual charges in one category and month, under its row in
/// Over time and on the budget. Money in (an income line) reads as it came
/// in; spending reads as what went out.
struct CategoryCharges: View {
    let moneyIn: Bool
    let month: Month
    let category: String
    @Query private var records: [TransactionRecord]

    init(month: Month, category: String, moneyIn: Bool = false) {
        self.moneyIn = moneyIn
        self.month = month
        self.category = category
        let first = month.firstDay.ordinal
        let last = month.adding(1).firstDay.ordinal
        if category == Spending.uncategorized {
            _records = Query(
                filter: #Predicate<TransactionRecord> { $0.category == nil && $0.dayOrdinal >= first && $0.dayOrdinal < last },
                sort: \.dayOrdinal)
        } else {
            // The month's filed ones, so a split's part in this category shows too (seam 43).
            _records = Query(
                filter: #Predicate<TransactionRecord> { $0.category != nil && $0.dayOrdinal >= first && $0.dayOrdinal < last },
                sort: \.dayOrdinal)
        }
    }

    /// Each charge in this category, a split one by its part here.
    private var charges: [(record: TransactionRecord, amount: Decimal)] {
        guard category != Spending.uncategorized else { return records.map { ($0, $0.amount) } }
        return records.compactMap { record in
            guard record.splitsData != nil else { return record.category == category ? (record, record.amount) : nil }
            return record.splits.first { $0.category == category }.map { (record, $0.amount) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            let charges = charges
            if charges.isEmpty {
                // A bill that hasn't come yet opens to this, not to nothing.
                Text("Nothing in \(month.name).").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            ForEach(charges, id: \.record.id) { record, amount in
                HStack {
                    Text(Day(ordinal: record.dayOrdinal).startDate(in: .current).formatted(.dateTime.month(.abbreviated).day()))
                        .monospacedDigit().foregroundStyle(Palette.inkSecondary).frame(width: 56 * TextSize.current.scale, alignment: .leading)
                    Text(record.merchant).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer()
                    Text((moneyIn ? amount : -amount).dollars).monospacedDigit().foregroundStyle(Palette.inkSecondary).privateAmount()
                }
                .font(Typeface.detail)
            }
        }
    }
}
