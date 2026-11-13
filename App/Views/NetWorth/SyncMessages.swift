import Charts
import Core
import SwiftData
import SwiftUI

struct SyncMessages: View {
    @Environment(SyncService.self) private var sync
    @Query(sort: \SyncRunRecord.startedAt, order: .reverse) private var runs: [SyncRunRecord]

    var body: some View {
        let today = Day(.now, in: .current)
        let health = Staleness.syncHealth(
            lastAttempt: runs.first.map { Day($0.startedAt, in: .current) },
            lastAttemptFailed: runs.first.map { !$0.succeeded } ?? false,
            lastSuccess: runs.first(where: \.succeeded).map { Day($0.startedAt, in: .current) },
            today: today
        )
        // Only while connected: after a disconnect there's nothing to sync.
        if sync.lastError == nil, sync.isConnected, case .overdue(let days) = health {
            Label(
                "Your banks haven't synced in \(days) days. Choose Sync Now to catch up.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(Typeface.body).foregroundStyle(Palette.behind)
        }
        if sync.lastError == nil, sync.isConnected, case .lastSyncFailed(let lastSuccess) = health {
            Label(
                lastSuccess.map {
                    "The last sync failed. Synced balances are from \($0.startDate(in: .current).formatted(date: .abbreviated, time: .omitted))."
                }
                    ?? "The last sync failed, so synced balances may be out of date.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(Typeface.body).foregroundStyle(Palette.behind)
        }
        if let message = sync.lastError {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Typeface.body)
                .foregroundStyle(Palette.failure)
        }
        ForEach(sync.problems, id: \.self) { problem in
            Label(problem, systemImage: "info.circle")
                .font(Typeface.body)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}
