import Core
import Foundation
import SwiftData

/// Writes a backup bundle to disk away from the main thread: the same dated
/// folder `CompassStore.exportBackup` makes (the JSON bundle plus balances
/// and transactions as CSVs). The bundle comes from
/// `CompassStore.backupBundle(in:at:)`, read off the main thread too.
enum BackupWriter {
    /// Returns the new folder inside `folder`.
    nonisolated static func write(_ bundle: BackupBundle, into folder: URL) throws -> URL {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let day = Day(bundle.exportedAt, in: .current)
        let name = String(format: "Compass Backup %04d-%02d-%02d", day.year, day.month, day.dayOfMonth)
        var destination = folder.appending(path: name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appending(path: "\(name) \(suffix)")
            suffix += 1
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Backup.json(bundle).write(to: destination.appending(path: "compass-backup.json"), options: .atomic)
        try Data(Backup.balancesCSV(snapshots: bundle.snapshots, accounts: bundle.accounts).utf8)
            .write(to: destination.appending(path: "balances.csv"), options: .atomic)
        try Data(Backup.transactionsCSV(bundle.transactions, accounts: bundle.accounts, goals: bundle.goals).utf8)
            .write(to: destination.appending(path: "transactions.csv"), options: .atomic)
        return destination
    }

    /// Today's automatic backup (just the JSON bundle) in `folder`, replacing
    /// any from earlier today, keeping the newest two weeks.
    nonisolated static func writeDaily(_ bundle: BackupBundle, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Backup.dailyName(for: Day(bundle.exportedAt, in: .current))
        try Backup.json(bundle).write(to: folder.appending(path: name), options: .atomic)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        for old in Backup.expiredDaily(names, keep: 14) {
            try? FileManager.default.removeItem(at: folder.appending(path: old))
        }
    }

    /// Backs up the real store once a day while Compass runs, in a folder
    /// beside it, so a loss can be put back from the day before.
    static func startDaily(container: ModelContainer, folder: URL) {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                let today = Backup.dailyName(for: Day(.now, in: .current))
                if !FileManager.default.fileExists(atPath: folder.appending(path: today).path),
                    let bundle = try? CompassStore.backupBundle(in: ModelContext(container), at: .now)
                {
                    try? writeDaily(bundle, into: folder)
                }
                try? await Task.sleep(for: .seconds(3 * 3600))
            }
        }
    }
}
