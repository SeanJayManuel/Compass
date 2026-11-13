import Core
import SwiftData
import SwiftUI

/// The month's transactions under the budget, newest day first, each day
/// with what it spent. Closed until they open it, since a month is dozens of
/// cards. Each day is its own child of the screen's lazy stack, so a busy
/// month only builds the days on screen. The rows come from the screen's own
/// fetch, and each category is a plain button whose picker is built only
/// when clicked, so opening Spending builds no menus.
struct MonthTransactions: View {
    @Query(sort: \AccountRecord.createdAt) private var accountRecords: [AccountRecord]
    @Query private var kindRecords: [CategoryKindRecord]
    @Query(sort: \GoalRecord.createdAt) private var goalRecords: [GoalRecord]
    /// Whether the list is open; it stays as they leave it.
    @Remembered("spending.transactions.expanded") private var expanded = false
    let month: Month
    /// This month's transactions, merchant included.
    let transactions: [Core.Transaction]
    /// Unfiled ones matched as transfers, which a day's header leaves out.
    let transfers: Set<UUID>

    var body: some View {
        Button {
            withAnimation(Motion.change) { expanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11 * TextSize.current.scale, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
                Text("Transactions").font(Typeface.section).foregroundStyle(Palette.ink)
                Spacer()
                Text(transactions.count == 1 ? "1 in \(month.name)" : "\(transactions.count.formatted()) in \(month.name)")
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Hides the month's transactions" : "Shows the month's transactions")
        .padding(.top, Spacing.s)

        // Only an open list is grouped and built, so a closed one costs nothing.
        if expanded {
            let kinds = Dictionary(
                kindRecords.compactMap { record in
                    CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
                }, uniquingKeysWith: { first, _ in first })
            let days = TransactionSearch.byDay(transactions, kinds: kinds, transfers: transfers)
            let names = Dictionary(accountRecords.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let goalNames = Dictionary(goalRecords.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

            if days.isEmpty {
                Text("No transactions in \(month.name).").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    .card(padding: Spacing.l)
            }
            ForEach(days) { day in
                TransactionDayCard(day: day, accountNames: names, goalNames: goalNames)
            }
        }
    }
}
