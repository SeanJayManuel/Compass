import Core
import Foundation
import Observation
import SwiftData

/// What ⌘K searches, kept between openings: read in the background a few
/// seconds after launch, marked stale by any save, and read again the next
/// time the panel opens (which searches the last read until then). Reading
/// every transaction takes most of a second, so the panel never waits on it
/// after the first time.
@Observable
final class SearchCache {
    /// Nil until the first read is in.
    private(set) var loaded: SearchLoaded?
    /// Bumped with each read, for views keyed on it.
    private(set) var version = 0

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var stale = true
    @ObservationIgnored private var reading = false

    init(container: ModelContainer) {
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stale = true }
        }
        // After launch has settled, so the first ⌘K finds it ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refreshIfNeeded(priority: .utility) }
    }

    /// Reads again if anything was saved since the last read (or there's none yet).
    func refreshIfNeeded(priority: TaskPriority = .userInitiated) {
        guard stale, !reading else { return }
        stale = false
        reading = true
        let container = container
        Task.detached(priority: priority) { [weak self] in
            let read = Self.read(container)
            await MainActor.run {
                guard let self else { return }
                self.loaded = read
                self.version += 1
                self.reading = false
                // Saved during the read: the next opening reads again.
            }
        }
    }

    /// Everything searchable, in a context of its own.
    nonisolated private static func read(_ container: ModelContainer) -> SearchLoaded {
        let context = ModelContext(container)
        let accounts = context.all(AccountRecord.self)
        let kinds = context.all(CategoryKindRecord.self)
        let goals = context.all(GoalRecord.self)
        let habits = context.all(HabitRecord.self).compactMap(\.habit)
        let entries = context.all(PlaybookEntryRecord.self).compactMap(\.entry)
        let notes = context.all(NoteRecord.self).compactMap(\.note)

        // Transactions a batch at a time, so their models never all sit in
        // memory at once (the index is a fraction of their size).
        let names = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var lines: [String: SearchLoaded.Line] = [:]
        var transactions: [SearchItem] = []
        var filed: Set<String> = []
        var descriptor = FetchDescriptor<TransactionRecord>()
        descriptor.propertiesToFetch = [\.id, \.accountID, \.dayOrdinal, \.merchant, \.statement, \.category]
        try? context.enumerate(descriptor, batchSize: 2_000) { record in
            let id = record.id.uuidString
            if let category = record.category { filed.insert(category) }
            lines[id] = SearchLoaded.Line(day: record.dayOrdinal, category: record.category, account: names[record.accountID])
            transactions.append(
                SearchItem(
                    kind: .transaction, id: id, title: record.merchant, detail: record.statement,
                    day: Day(ordinal: record.dayOrdinal)))
        }

        var found = accounts.map {
            SearchItem(
                kind: .account, id: $0.id.uuidString, title: $0.name, detail: $0.institution ?? "",
                inactive: $0.archivedOrdinal != nil)
        }
        let categories = Set(kinds.map(\.category)).union(filed)
        found += categories.map { SearchItem(kind: .category, id: $0, title: $0) }
        found += goals.map {
            SearchItem(kind: .goal, id: $0.id.uuidString, title: $0.name, inactive: $0.statusRaw == "retired")
        }
        found += habits.map { SearchItem(kind: .habit, id: $0.id.uuidString, title: $0.title, inactive: $0.archived) }
        found += entries.map { SearchItem(kind: .playbook, id: $0.id.uuidString, title: $0.title, detail: $0.area) }
        found += notes.map { SearchItem(kind: .note, id: $0.id.uuidString, title: $0.title, detail: "\($0.topic) · \($0.body)") }

        found += transactions
        return SearchLoaded(index: QuickSearchIndex(found), lines: lines)
    }
}

/// What the search panel searches.
nonisolated struct SearchLoaded: Sendable {
    /// What a transaction's row says under its merchant: day, category and
    /// account, put into words only for the rows on screen.
    struct Line: Sendable {
        var day: Int
        var category: String?
        var account: String?
        var text: String {
            let date = Day(ordinal: day).startDate(in: .current).formatted(date: .abbreviated, time: .omitted)
            return [date, category, account].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var index: QuickSearchIndex
    var lines: [String: Line]
}
