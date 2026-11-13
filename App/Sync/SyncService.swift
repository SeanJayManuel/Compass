import Core
import Foundation
import Observation
import SwiftData

/// Connects to SimpleFIN and runs Sync Now. Every attempt is logged as a
/// SyncRunRecord, and any failure ends up in `lastError` for the UI.
@Observable
final class SyncService {
    private(set) var isSyncing = false
    private(set) var isConnected: Bool
    private(set) var lastError: String?
    private(set) var problems: [String] = []

    private let client: SimpleFINClient
    private let keychain: Keychain
    private let context: ModelContext

    init(context: ModelContext, keychain: Keychain, client: SimpleFINClient = SimpleFINClient()) {
        self.context = context
        self.keychain = keychain
        self.client = client
        isConnected = keychain.exists()
    }

    func connect(setupToken: String) async {
        await run {
            let accessURL = try await client.claim(setupToken: setupToken)
            try keychain.write(accessURL)
            isConnected = true
            return try await syncAccounts(accessURL: accessURL)
        }
    }

    /// Forgets the saved access URL. Accounts and history stay.
    func disconnect() {
        keychain.delete()
        isConnected = false
    }

    func sync() async {
        await run {
            guard let accessURL = keychain.read() else {
                isConnected = false
                throw SimpleFINClient.Failure.badAccessURL
            }
            return try await syncAccounts(accessURL: accessURL)
        }
    }

    /// Syncs once a day without being asked, when Compass opens or unlocks.
    /// Debug runs that drive the app, and sandbox data unless `--auto-sync`
    /// is passed, never sync on their own.
    func syncIfDue() async {
        guard Self.autoSyncAllowed, !isSyncing else { return }
        let since = Date.now.addingTimeInterval(-2 * 86_400)
        // Unknown runs mean an unknown count against the Bridge's daily limit,
        // so a failed read skips the automatic sync rather than risk the token.
        let runs: [SyncRunRecord]
        do {
            runs = try context.fetch(FetchDescriptor<SyncRunRecord>(predicate: #Predicate { $0.startedAt >= since }))
        } catch {
            storeLog.error("Couldn't read recent syncs, so not syncing on its own: \(error.localizedDescription, privacy: .public)")
            return
        }
        let attempts = runs.map { SyncAttempt(startedAt: $0.startedAt, succeeded: $0.succeeded) }
        guard AutoSync.shouldSync(attempts: attempts, connected: isConnected, now: .now, timeZone: .current) else { return }
        await sync()
    }

    private static var autoSyncAllowed: Bool {
        let arguments = CommandLine.arguments
        let driven = ["--self-check", "--perf-run", "--seed-perf", "--seed-demo", "--seed-only"]
        if driven.contains(where: arguments.contains) { return false }
        return DataEnvironment.current == .real || arguments.contains("--auto-sync")
    }

    private func syncAccounts(accessURL: String) async throws -> Int {
        let store = CompassStore(context: context)
        let today = Day(.now, in: .current)
        // From the newest synced transaction, not the last sync: syncs before
        // transactions were fetched mustn't cut the first 90-day backfill short.
        let since = SyncMerge.transactionWindowStart(lastSynced: try store.newestSyncedTransactionDay(), today: today)
        let fetched = try await client.fetchAccounts(accessURL: accessURL, transactionsSince: since.startDate(in: .current))
        let plan = SyncMerge.plan(
            fetched: fetched.accounts, existing: try store.accounts(), pins: try store.pins(), timeZone: .current
        )
        let accounts = try store.accounts() + plan.newAccounts
        try store.insert(
            SyncMerge.newTransactions(
                fetched: fetched.accounts, accounts: accounts, knownExternalIDs: try store.knownExternalIDs(),
                rules: try store.filingRules(), timeZone: .current, today: today
            ), pendingReview: true)
        try store.apply(plan)
        try store.removeDuplicateTransactions()
        // After dedupe, so a Monarch copy can't pair up and then be deleted.
        try store.fileTransfers(since: since)
        // Last, so a guess never hides a transfer that only pairs while unfiled.
        try store.guessOpenCategories()
        problems = fetched.problems
        return plan.snapshots.count
    }

    /// Runs one sync attempt and records how it went.
    private func run(_ work: () async throws -> Int) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        let record = SyncRunRecord(startedAt: .now)
        do {
            record.accountsUpdated = try await work()
            record.succeeded = true
        } catch {
            // Drop anything a failed sync left half-written, then log the attempt.
            context.rollback()
            lastError = error.localizedDescription
            record.error = error.localizedDescription
        }
        record.finishedAt = .now
        context.insert(record)
        do {
            try context.save()
        } catch {
            // Nothing from this run was saved: drop it rather than leave it for
            // the next save to write half-done.
            storeLog.error("Couldn't save the sync run: \(error.localizedDescription, privacy: .public)")
            context.rollback()
            lastError = "Compass couldn't save this sync (\(error.localizedDescription))."
            // The request still reached the Bridge, so it still counts against
            // the daily limit: keep a failed run, even if it only stays pending.
            let failed = SyncRunRecord(startedAt: record.startedAt)
            failed.finishedAt = record.finishedAt
            failed.error = lastError
            context.insert(failed)
            try? context.save()
        }
        isSyncing = false
    }
}
