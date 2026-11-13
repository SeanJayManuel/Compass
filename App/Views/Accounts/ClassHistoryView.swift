import Core
import SwiftUI

/// One account class's own total over time, on its own line rather than
/// stacked with the others. Read from the cached breakdown, so it costs no
/// fetch; it's only built while the card is expanded.
struct ClassHistoryView: View {
    let accountClass: AccountClass
    /// The card's accounts, to say what the line leaves out.
    let accounts: [Account]
    /// Every archived account, to say which ones the line still holds.
    let archived: [Account]
    @Environment(NetWorthCache.self) private var cache

    var body: some View {
        BalanceHistoryPanel(
            series: NetWorthSeries.classSeries(cache.breakdown, for: accountClass),
            measure: BalanceHistoryMeasure(accountClass),
            color: Palette.accountClass(accountClass),
            today: cache.today,
            // Grows with the Settings text size, as the type around it does.
            chartHeight: 180 * TextSize.current.scale,
            note: notes,
            emptyMessage: emptyMessage
        )
    }

    private var emptyMessage: String {
        let counted = accounts.filter { !$0.excludedFromNetWorth }
        if counted.isEmpty {
            return "None of these accounts count in net worth, so there's no class total to draw. Click an account to see its own history."
        }
        // The line starts the first day the class held anything, so a class
        // that has only ever held $0 has no line. Its balances are there.
        if counted.contains(where: { cache.latest[$0.id] != nil }) {
            return accountClass == .debt
                ? "Nothing owed so far. Every balance in this class has been $0."
                : "Every balance in this class has been $0 so far."
        }
        return "No balance history for this class yet."
    }

    private var notes: String? {
        let parts = [excludedNote, archivedNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var excludedNote: String? {
        let excluded = accounts.filter(\.excludedFromNetWorth).count
        guard excluded > 0, excluded < accounts.count else { return nil }
        return excluded == 1 ? "Leaves out the account not counted in net worth." : "Leaves out the \(excluded) accounts not counted in net worth."
    }

    /// The card lists only active accounts, but the line counts an archived
    /// one until the day it was archived, as net worth does. Without this, its
    /// drop on that day reads as a loss.
    private var archivedNote: String? {
        let held = NetWorthSeries.archivedInClassLine(archived, for: accountClass, latest: cache.latest, today: cache.today)
        guard let first = held.first else { return nil }
        if held.count == 1, let day = first.archivedOn {
            // Monarch names can carry trailing spaces.
            let name = first.name.trimmingCharacters(in: .whitespaces)
            return "Includes \(name) until it was archived on \(day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted))."
        }
        return "Includes \(held.count) archived accounts until the day each was archived."
    }
}
