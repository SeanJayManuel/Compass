import Core
import Foundation
import Observation
import SwiftData

/// Everything the money screens derive from balances, computed once and kept
/// on disk: the daily breakdown, each account's latest balance and each
/// goal's progress. Launch reads the file instead of every balance; a
/// recompute runs only when balances, accounts or goals change, or on a new day.
/// Life goals linked to these numbers are checked whenever either side changes.
@Observable
final class NetWorthCache {
    private(set) var breakdown: [DailyBreakdown] = []
    private(set) var latest: [UUID: LatestBalance] = [:]
    private(set) var goalProgress: [UUID: GoalProgress] = [:]
    private(set) var today = Day(.now, in: .current)

    /// The numbers a life goal can follow: net worth, and each money goal's measured value.
    var linkedValues: [LinkedMeasure: Decimal] {
        var values: [LinkedMeasure: Decimal] = [:]
        if let total = breakdown.last?.total { values[.netWorth] = total }
        for (id, progress) in goalProgress { values[.moneyGoal(id)] = progress.current }
        return values
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Writes the file in the order results are published, so it always ends
    /// up holding the newest numbers.
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "Compass.NetWorthCache.write", qos: .utility)
    @ObservationIgnored private var ignoreGoalsOnlySave = false
    @ObservationIgnored private var linkedCheckPending = false

    nonisolated private struct Payload: Codable, Sendable {
        /// 2: opening balances (Oct 30, 2026). 4: pace from pay settings (Oct 31, 2026).
        static let currentVersion = 4
        var version = currentVersion
        var day: Day
        var breakdown: [DailyBreakdown]
        var latest: [UUID: LatestBalance]
        var goalProgress: [UUID: GoalProgress]
    }

    init(container: ModelContainer, storeURL: URL) {
        self.container = container
        fileURL = storeURL.deletingPathExtension().appendingPathExtension("cache.json")

        let saved = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        if let saved, saved.version == Payload.currentVersion {
            breakdown = NetWorthSeries.extend(saved.breakdown, through: today)
            latest = saved.latest
            goalProgress = saved.goalProgress
            // A life goal may follow a number the saved values already pass.
            checkLinkedLifeGoalsSoon()
        }
        // Without a cache (or one an older version wrote), or on a new day (pace
        // and projections move), recompute once the first frame is up.
        if saved?.version != Payload.currentVersion || saved?.day != today {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }

        observers.append(
            NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
                let change = Self.change(in: note)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch change {
                    case .none: return
                    case .lifeGoalsOnly: self.checkLinkedLifeGoalsSoon()
                    case .goalsOnly where self.ignoreGoalsOnlySave: self.ignoreGoalsOnlySave = false
                    case .goalsOnly, .data: self.refresh()
                    }
                }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: .goalPaymentsChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
    }

    private enum Change { case none, lifeGoalsOnly, goalsOnly, data }

    /// Only balances, accounts, goals and pay settings (an invested goal's
    /// pace reads payroll) feed the cache; saving a filed
    /// transaction or a sync log doesn't need a recompute. A saved life goal
    /// only needs checking against the numbers already here.
    nonisolated private static func change(in note: Notification) -> Change {
        guard let entities = ModelContext.savedEntityNames(in: note) else { return .data }
        if entities.contains("SnapshotRecord") || entities.contains("AccountRecord") || entities.contains("PayProfileRecord") { return .data }
        if entities.contains("GoalRecord") { return .goalsOnly }
        return entities.contains("LifeGoalRecord") ? .lifeGoalsOnly : .none
    }

    /// Recomputes on a background thread, then publishes on the main thread
    /// and saves the file. A newer request supersedes an older one still
    /// running: the older one's numbers reach neither the screen nor the file.
    func refresh() {
        generation += 1
        let generation = generation
        let container = container
        let today = Day(.now, in: .current)
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.compute(container: container, today: today)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.publish(result, generation: generation) }
        }
    }

    nonisolated private struct Computed: Sendable {
        var payload: Payload
        /// Goals whose target was reached since the last look.
        var achievements: [UUID: GoalStatus]
    }

    nonisolated private static func compute(container: ModelContainer, today: Day) -> Computed {
        // A context of its own, so the 90,000-odd balances are released when
        // this returns and the main thread never waits on the fetch.
        let context = ModelContext(container)
        let accounts = context.all(AccountRecord.self).map(\.account)
        let snapshots = context.all(SnapshotRecord.self).map(\.snapshot)
        var goals = context.all(GoalRecord.self).map(\.goal)
        // Money moved into a newly linked account isn't an opening balance.
        let transactions = context.all(TransactionRecord.self).map(\.transaction)
        let kinds = Dictionary(
            context.all(CategoryKindRecord.self).compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            }, uniquingKeysWith: { first, _ in first })
        let moves = NetWorthSeries.moves(in: transactions, kinds: kinds)
        // Pay tells the 401(k)'s and stock plan's contributions, for an invested goal's pace.
        let pay = context.all(PayProfileRecord.self).first?.profile ?? PayProfile().guessingAccounts(accounts)
        let payroll =
            (try? CompassStore.payroll(
                profile: pay, transactions: transactions, kinds: kinds,
                months: Month(today).adding(-3)...Month(today), today: today, in: context)) ?? Payroll()

        let breakdown = NetWorthSeries.breakdown(accounts: accounts, snapshots: snapshots, through: today, moves: moves)
        // A goal that paid for things counts what's left once the money's moved out.
        let ledger = GoalFunding.ledger(goals: goals, transactions: transactions, kinds: kinds)
        var achievements: [UUID: GoalStatus] = [:]
        var progress: [UUID: GoalProgress] = [:]
        for index in goals.indices {
            let measured = GoalFunding.available(
                GoalProgress.measured(
                    goals[index], accounts: accounts, snapshots: snapshots,
                    today: today, breakdown: breakdown, moves: moves),
                goal: goals[index].id, ledger: ledger)
            let updated = GoalLifecycle.update(goals[index], measured: measured)
            if updated.status != goals[index].status {
                achievements[updated.id] = updated.status
                goals[index] = updated
            }
            progress[goals[index].id] = Self.progress(
                goals[index], measured: measured, accounts: accounts, snapshots: snapshots,
                transactions: transactions, kinds: kinds, payroll: payroll, today: today)
        }
        return Computed(
            payload: Payload(day: today, breakdown: breakdown, latest: Staleness.latest(snapshots: snapshots), goalProgress: progress),
            achievements: achievements
        )
    }

    /// An invested goal's pace is what they put in over the last three full
    /// months, with the market's part beside it; others pace by balance.
    nonisolated private static func progress(
        _ goal: Goal, measured: [DailyTotal], accounts: [Account], snapshots: [BalanceSnapshot],
        transactions: [Transaction], kinds: [String: CategoryKind], payroll: Payroll,
        today: Day
    ) -> GoalProgress {
        guard GoalProgress.isInvested(goal, accounts: accounts), case .accountTotal(let ids) = goal.kind else {
            return GoalProgress.evaluate(goal, measured: measured, today: today)
        }
        // Chosen accounts count even if excluded from net worth, as in `measured`.
        let chosen = accounts.filter { ids.contains($0.id) }.map { account in
            var counted = account
            counted.excludedFromNetWorth = false
            return counted
        }
        let month = Month(today)
        let report = Contributions.report(
            accounts: chosen, snapshots: snapshots, transactions: transactions,
            kinds: kinds, today: today, months: month.adding(-3)...month, payroll: payroll)
        let pace = Contributions.pace(report, before: month)
        var progress = GoalProgress.evaluate(goal, measured: measured, today: today, contributionPace: pace.perMonth)
        if progress.paceFromContributions {
            progress.marketPerMonth = pace.marketPerMonth
            progress.paceLeavesOut = pace.untold
        }
        return progress
    }

    /// A goal's measured value by day, for its detail chart. Net worth and FIRE
    /// goals come from the breakdown already in memory; account totals read
    /// their balances off the main thread.
    func series(for goal: Goal) async -> [DailyTotal] {
        switch goal.kind {
        case .netWorth, .fire:
            return GoalProgress.measured(goal, accounts: [], snapshots: [], today: today, breakdown: breakdown)
        case .accountTotal:
            return await Self.accountSeries(for: goal, container: container, today: today)
        }
    }

    /// Fetches in a context of its own, as `compute` does, so the balances are
    /// released when this returns and the main thread never waits on them.
    @concurrent nonisolated private static func accountSeries(for goal: Goal, container: ModelContainer, today: Day) async -> [DailyTotal] {
        let context = ModelContext(container)
        let accounts = context.all(AccountRecord.self).map(\.account)
        let snapshots = context.all(SnapshotRecord.self).map(\.snapshot)
        let ledger = GoalFunding.ledger(in: context)
        return GoalFunding.available(
            GoalProgress.measured(goal, accounts: accounts, snapshots: snapshots, today: today),
            goal: goal.id, ledger: ledger)
    }

    private func publish(_ result: Computed, generation: Int) {
        guard generation == self.generation else { return }
        let payload = result.payload, fileURL = fileURL
        writeQueue.async { try? JSONEncoder().encode(payload).write(to: fileURL, options: .atomic) }
        today = result.payload.day
        breakdown = result.payload.breakdown
        latest = result.payload.latest
        goalProgress = result.payload.goalProgress
        refreshLinkedLifeGoals()

        // Goals are achieved by data, not by someone noticing. Saving the new
        // status doesn't need another recompute: progress above already has it.
        guard !result.achievements.isEmpty else { return }
        let context = container.mainContext
        for record in context.all(GoalRecord.self) {
            guard let status = result.achievements[record.id], record.statusRaw == "active" else { continue }
            var goal = record.goal
            goal.status = status
            record.update(from: goal)
        }
        // Only a save that happens posts the notification the flag waits for.
        guard context.hasChanges else { return }
        ignoreGoalsOnlySave = true
        do { try context.save() } catch { storeLog.error("Couldn't save reached goals: \(error.localizedDescription, privacy: .public)") }
    }

    /// A saved life goal only needs checking against the numbers already
    /// here, not a recompute. The check runs on the next main-queue turn, so
    /// it never saves inside another save's notification, and runs once
    /// however many saves asked for it (pasting a plan saves goal by goal).
    /// Its own save asks once more, finds nothing new to mark, and stops.
    private func checkLinkedLifeGoalsSoon() {
        guard !linkedCheckPending else { return }
        linkedCheckPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.linkedCheckPending = false
            self.refreshLinkedLifeGoals()
        }
    }

    /// Life goals that follow a number are done the first time it reaches
    /// their target. Only goals whose status changed are written.
    private func refreshLinkedLifeGoals() {
        let context = container.mainContext
        let records = context.all(LifeGoalRecord.self)
        let goals = records.compactMap(\.goal)
        let refreshed = LifeGoals.refreshLinked(goals, values: linkedValues, today: today)
        var changed = false
        for (before, after) in zip(goals, refreshed) where before != after {
            guard let record = records.first(where: { $0.id == after.id }),
                let data = try? JSONEncoder().encode(after)
            else { continue }
            record.goalData = data
            changed = true
        }
        if changed {
            do { try context.save() } catch { storeLog.error("Couldn't save linked life goals: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

extension ModelContext {
    /// The model types a `didSave` notification touched, like
    /// "TransactionRecord", or nil when it doesn't say (treat that as anything).
    nonisolated static func savedEntityNames(in note: Notification) -> Set<String>? {
        let keys: [NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        let entities = Set(keys.flatMap { (note.userInfo?[$0.rawValue] as? [PersistentIdentifier]) ?? [] }.map(\.entityName))
        return entities.isEmpty ? nil : entities
    }
}
