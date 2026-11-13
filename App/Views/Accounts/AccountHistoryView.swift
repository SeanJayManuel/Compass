import Combine
import Core
import SwiftData
import SwiftUI

/// One account's own balance over time. Fetches only that account's balances,
/// off the main thread, when its row is opened, and again when balances change.
struct AccountHistoryView: View {
    let account: Account
    @Environment(\.modelContext) private var context
    @Environment(NetWorthCache.self) private var cache
    /// Nil until the first fetch lands; a refetch keeps the previous line up.
    @State private var series: [DailyTotal]?
    @State private var failed = false
    @State private var balanceSaves = 0

    /// Grows with the Settings text size, as the type around it does.
    private var chartHeight: CGFloat { 140 * TextSize.current.scale }

    private struct LoadKey: Hashable {
        var accountID: UUID
        /// Decide the line's sign and where it ends; a rename doesn't refetch.
        var accountClass: AccountClass
        var archivedOn: Day?
        var through: Day
        var balanceSaves: Int
    }

    var body: some View {
        let measure = BalanceHistoryMeasure(account.accountClass)
        Group {
            if let series {
                BalanceHistoryPanel(
                    series: series,
                    measure: measure,
                    color: Palette.accountClass(account.accountClass),
                    today: cache.today,
                    chartHeight: chartHeight,
                    note: staleNote,
                    emptyMessage: account.source == .simplefin
                        ? "No balances yet. Sync to start its history."
                        : "No balances yet. Log a balance to start its history."
                )
            } else if failed {
                Text("Compass couldn't read this account's balances. Close the row and open it again to retry.")
                    .font(Typeface.detail).foregroundStyle(Palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // About the panel's height, so the card doesn't jump when the line arrives.
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: chartHeight + 56)
            }
        }
        .task(
            id: LoadKey(
                accountID: account.id, accountClass: account.accountClass, archivedOn: account.archivedOn,
                through: cache.today, balanceSaves: balanceSaves)
        ) {
            // A run of saves (an import, a sync) refetches once, after the last.
            if series != nil {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            let container = context.container
            let account = account
            let today = cache.today
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.history(container: container, account: account, today: today)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded {
                series = loaded
                failed = false
            } else if series == nil {
                failed = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: DispatchQueue.main)) { note in
            if Self.touchesBalances(note) { balanceSaves += 1 }
        }
    }

    /// A stale balance carries forward as a flat line; say so, and what fixes
    /// it. Not for archived accounts: nothing new is coming.
    private var staleNote: String? {
        guard account.archivedOn.map({ $0 > cache.today }) ?? true,
            let latest = cache.latest[account.id],
            case .stale = Staleness.freshness(source: account.source, lastUpdated: latest.day, today: cache.today)
        else { return nil }
        let day = latest.day.startDate(in: .current).formatted(date: .abbreviated, time: .omitted)
        let fix = account.source == .simplefin ? "Sync" : "Log a new balance"
        return "The line stays flat after \(day), its last balance. \(fix) to bring it up to date."
    }

    /// The account's own line (`NetWorthSeries.accountSeries`). Nil if the
    /// fetch fails. Its own context, so the main thread never waits on it.
    nonisolated private static func history(container: ModelContainer, account: Account, today: Day) -> [DailyTotal]? {
        let context = ModelContext(container)
        let accountID = account.id
        var descriptor = FetchDescriptor<SnapshotRecord>(predicate: #Predicate { $0.accountID == accountID })
        // Only what the line needs: reading each stored field costs time.
        descriptor.propertiesToFetch = [\.dayOrdinal, \.sourceRaw, \.balance]
        guard let records = try? context.fetch(descriptor) else { return nil }
        let snapshots = records.map { record in
            BalanceSnapshot(
                accountID: accountID, day: Day(ordinal: record.dayOrdinal),
                source: BalanceSource(rawValue: record.sourceRaw) ?? .manual, balance: record.balance)
        }
        return NetWorthSeries.accountSeries(account, snapshots: snapshots, through: today)
    }

    /// Saves that add, change or remove balances or accounts (a merge moves
    /// history), which is when the line needs fetching again. The same test
    /// NetWorthCache uses to decide on a recompute.
    nonisolated private static func touchesBalances(_ note: Notification) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        let entities = Set(keys.flatMap { (note.userInfo?[$0.rawValue] as? [PersistentIdentifier]) ?? [] }.map(\.entityName))
        return entities.isEmpty || entities.contains("SnapshotRecord") || entities.contains("AccountRecord")
    }
}
