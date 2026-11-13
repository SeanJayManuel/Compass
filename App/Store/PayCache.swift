import Core
import Foundation
import Observation
import SwiftData

/// The paychecks that arrived, read once off the main thread and shared by
/// the screens that plan with them (the Money overview's flexible spending,
/// the menu bar panel, Spending). Read again only when a save touches
/// transactions or pay settings, so drawing a screen never reads deposits.
@Observable
final class PayCache {
    /// Nil until the first read is in.
    private(set) var paychecks: [PaycheckDeposit]?
    /// The saved pay settings they were read with (nil for none saved).
    private(set) var profileData: Data?
    /// Bumped when a read finds something new, for views keyed on it.
    private(set) var version = 0

    /// The paychecks read with these saved pay settings; nil until they're
    /// in, and while settings just changed are being read again.
    func paychecks(forProfile data: Data?) -> [PaycheckDeposit]? {
        profileData == data ? paychecks : nil
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            guard Self.touchesPay(note) else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Reads on a background thread; a newer read supersedes one still running.
    func refresh() {
        generation += 1
        let generation = generation
        let container = container
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            let context = ModelContext(container)
            let record = context.all(PayProfileRecord.self).first
            let data = record?.profileData
            let found = (try? CompassStore.paychecks(record?.profile ?? PayProfile(), in: context)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == generation else { return }
                // Most saves (a note, a sync) leave the paychecks as they were.
                guard found != self.paychecks || data != self.profileData else { return }
                self.paychecks = found
                self.profileData = data
                self.version += 1
            }
        }
    }

    /// Deposits and pay settings decide the paychecks; a save that doesn't
    /// say what it touched might have.
    nonisolated private static func touchesPay(_ note: Notification) -> Bool {
        guard let entities = ModelContext.savedEntityNames(in: note) else { return true }
        return entities.contains("TransactionRecord") || entities.contains("PayProfileRecord")
    }
}
