import Core
import SwiftData
import SwiftUI

/// Every transaction, grouped by day as Spending lists a month, searchable
/// by merchant or statement, filtered by category and month, and refiled in
/// place.
///
/// Opening it reads only the newest page, off the main thread, so the first
/// frame never waits on the whole history. The whole history is read into a
/// search index in the background a moment later, or at once when a search
/// or scrolling to the end needs it. Leaving the screen cancels that and
/// lets it go. The days sit in a lazy stack, so only those on screen are
/// built, and the header with the search field stays put above them.
struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(Navigator.self) private var navigator
    @Query(sort: \AccountRecord.createdAt) private var accountRecords: [AccountRecord]
    @Query private var kindRecords: [CategoryKindRecord]
    @Query(sort: \GoalRecord.createdAt) private var goalRecords: [GoalRecord]
    @State private var refiling = Refiling()
    @State private var selectedTransaction: Core.Transaction?
    @Remembered("transactions.summary") private var showsSummary = false
    @State private var flow: TransactionSummary?
    /// With no search or filter: the last six months alone, read straight
    /// away, so the summary needn't wait for the whole history.
    @State private var recentFlow: TransactionSummary?
    @State private var resultsVersion = 0
    @State private var resultsQuery: TransactionQuery?
    /// Set only when results came from the current full index, never a preview page.
    @State private var resultsAt: Int?
    @State private var openedDebugTransaction = false
    @State private var matchedAt: Int?
    /// The newest transactions, read on open, ending at a day's end.
    @State private var page: [Core.Transaction] = []
    /// How many there are in all; nil until the first page is in.
    @State private var total: Int?
    /// Every month from the newest transaction back to the oldest.
    @State private var monthRange: [Month] = []
    /// Category names from merchant rules, kinds and the plan.
    @State private var known: Set<String> = []
    /// Every transaction, sorted and keyed for search.
    @State private var index: TransactionIndex?
    /// The `changes` count the index was read at, so a save rebuilds it.
    @State private var indexedAt: Int?
    /// Unfiled transactions matched as transfers, so a day's header leaves
    /// them out of what it spent: from the first page, then all history.
    @State private var matched: Set<UUID> = []
    /// Everything that matches, newest first.
    @State private var results: [Core.Transaction] = []
    /// How many of `results` to list; scrolling near the end adds more.
    @State private var shown = Self.pageSize
    /// The listed results by day, worked out when they or `shown` change
    /// rather than on every keystroke.
    @State private var days: [TransactionDay] = []
    /// How many transactions `days` holds.
    @State private var listed = 0
    @State private var text = ""
    @State private var category: CategoryFilter = .any
    @State private var month: Month?
    @State private var loaded = false
    /// The first page has taken long enough to say it's loading.
    @State private var slow = false
    /// The page read under way, so a superseded one's timer can't touch `slow`.
    @State private var reading = UUID()
    /// Bumped when a save touches transactions or category rules.
    @State private var changes = 0
    /// Bumped when the page or the index is replaced, so the filter runs again.
    @State private var pageVersion = 0
    @State private var indexVersion = 0
    /// The filter run the list already shows, listed with the page itself.
    @State private var listedFor: Refilter?
    /// The list is scrolled, so a rule sets the header off from it.
    @State private var scrolled = false
    @State private var position = ScrollPosition(edge: .top)
    @FocusState private var searching: Bool

    init() {
        // The newest page as the last visit left it, so coming back shows the
        // list from the first frame; it's read again behind it.
        guard let kept = TransactionsKept.page else { return }
        _page = State(initialValue: kept.first.transactions)
        _total = State(initialValue: kept.first.total)
        _monthRange = State(initialValue: kept.first.months)
        _known = State(initialValue: kept.first.known)
        _matched = State(initialValue: kept.matched)
        _results = State(initialValue: kept.first.transactions)
        _days = State(initialValue: kept.days)
        _listed = State(initialValue: kept.listed)
        // Already listed for opening's filter, so it isn't listed twice.
        _listedFor = State(initialValue: Refilter(query: TransactionQuery(text: "", category: .any, month: nil), page: 0, index: 0))
    }

    /// What opening the screen reads.
    static let pageSize = 200
    /// What scrolling near the end adds.
    static let morePage = 1_000
    /// How many days before the end the next lot is listed.
    private static let daysAhead = 8

    var body: some View {
        let query = TransactionQuery(text: text, category: category, month: month)
        let everything = Self.isEverything(query)
        let available = everything && index == nil ? total ?? 0 : results.count

        GeometryReader { geometry in
            let wide = geometry.size.width >= 940 * TextSize.current.scale
            VStack(alignment: .leading, spacing: 0) {
                header(everything: everything, available: available)
                    .screenColumn(.top)
                    .padding(.bottom, Spacing.m)
                    .overlay(alignment: .bottom) { Rule().opacity(scrolled ? 1 : 0) }
                if wide {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        transactionScroll(everything: everything, available: available, wide: true)
                        ScrollView { sidePanel.padding(.bottom, Spacing.xl) }
                            .frame(width: 300 * TextSize.current.scale)
                    }
                    .screenColumn([])
                } else {
                    transactionScroll(everything: everything, available: available, wide: false)
                }
            }
        }
        .onChange(of: query) {
            selectedTransaction = nil
            shown = Self.pageSize
            position.scrollTo(edge: .top)
        }
        .background(Palette.canvas)
        .refiling(refiling)
        .perfMark("screen.transactions")
        // A transaction picked in the search panel arrives as its merchant.
        .onAppear(perform: takeSearch)
        .onChange(of: navigator.transactionSearch) { takeSearch() }
        .task(id: changes) { await loadPage() }
        // Keyed on saves alone: starting a search while the history is being
        // read waits for that read rather than starting a second one.
        .task(id: changes) { await loadIndex() }
        .onReceive(
            NotificationCenter.default.publisher(for: ModelContext.didSave)
                .filter(Self.touchesTransactions)
                .receive(on: DispatchQueue.main)
        ) { _ in
            // Cleared here too, so the read this sets off can't be kept from before it.
            TransactionsKept.clear()
            changes += 1
        }
        .onChange(of: shown) { regroup() }
        // Filtering a long history runs off the main thread, a beat after typing stops.
        .task(id: Refilter(query: query, page: pageVersion, index: indexVersion)) {
            await refilter(query, everything: everything)
        }
        .task(id: RecentRequest(changes: changes, kinds: kinds)) { await summarizeRecent() }
        .task(
            id: SummaryRequest(
                query: query, results: resultsVersion, kinds: kinds,
                transfers: matched, changes: changes, matchedAt: matchedAt)
        ) {
            flow = nil
            guard index != nil, indexedAt == changes, matchedAt == changes, resultsAt == changes, resultsQuery == query else { return }
            let summary = await Self.summarize(results, kinds: kinds, transfers: matched)
            guard !Task.isCancelled else { return }
            flow = summary
        }
        .onDisappear {
            selectedTransaction = nil
            flow = nil
            matchedAt = nil
            // A long history is a lot to hold for a screen no one is looking at.
            index = nil
            indexedAt = nil
            results = []
            page = []
            days = []
            listed = 0
            // Coming back reads afresh, saying so rather than showing an empty
            // list, and waits again before reading the whole history.
            total = nil
            shown = Self.pageSize
        }
    }

    private func transactionScroll(everything: Bool, available: Int, wide: Bool) -> some View {
        ScrollView {
            list(everything: everything, available: available, wide: wide)
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.xl)
                .modifier(TransactionColumn(wide: wide))
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self) {
            $0.contentOffset.y > 1
        } action: { _, now in
            scrolled = now
        }
    }

    @ViewBuilder private var sidePanel: some View {
        if let selected = selectedTransaction {
            let transaction = newest.first { $0.id == selected.id } ?? selected
            TransactionInspector(
                transaction: transaction,
                account: accountRecords.first { $0.id == transaction.accountID }?.name ?? ""
            ) {
                selectedTransaction = nil
            }
            .id(transaction.id)
        } else {
            summaryPanel.card(padding: Spacing.l)
        }
    }

    private var summaryPanel: some View {
        let everything = Self.isEverything(TransactionQuery(text: text, category: category, month: month))
        return TransactionSummaryPanel(summary: everything ? recentFlow ?? flow : flow, focus: month)
    }

    /// The count and filters; the frame supplies the screen title.
    private func header(everything: Bool, available: Int) -> some View {
        let categories = known.union(index?.categories ?? []).union(page.compactMap(\.category))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let months = index?.months ?? monthRange

        return VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary(everything: everything, available: available))
                    .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            TransactionFilters(
                text: $text, category: $category, month: $month, searching: $searching,
                categories: categories, months: months)
        }
        // ⌘F finds, on this screen only: the shortcut leaves with it.
        .background {
            Button("Find") { searching = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Each day straight into the lazy stack, so only those on screen are
    /// built, then a last row that lists more as it comes into view.
    private func list(everything: Bool, available: Int, wide: Bool) -> some View {
        let names = Dictionary(accountRecords.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let goalNames = Dictionary(goalRecords.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let moreAt = days.count > Self.daysAhead ? days[days.count - Self.daysAhead].id : days.last?.id

        return LazyVStack(alignment: .leading, spacing: Spacing.m) {
            if !wide {
                if selectedTransaction != nil {
                    sidePanel
                } else {
                    DisclosureGroup("Summary", isExpanded: $showsSummary) { summaryPanel }
                        .font(Typeface.body)
                        .card(padding: Spacing.m)
                }
            }
            if total == 0 {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("No transactions yet").font(Typeface.figure).foregroundStyle(Palette.ink)
                    Text("Sync SimpleFIN or import Monarch transactions from the toolbar, and they'll be listed here.")
                        .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                }
                .card(padding: Spacing.xl)
            } else if total != nil, days.isEmpty, everything || index != nil {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Nothing matches.").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    Button("Show every transaction") {
                        text = ""
                        category = .any
                        month = nil
                    }
                    .linkButton()
                    .font(Typeface.body)
                }
                .card(padding: Spacing.l)
            }
            ForEach(days) { day in
                TransactionDayCard(
                    day: day, accountNames: names, goalNames: goalNames,
                    selectedID: selectedTransaction?.id,
                    openDetails: { transaction in
                        selectedTransaction = transaction
                        if !wide { position.scrollTo(edge: .top) }
                    }
                )
                .environment(\.rowDensity, .compact)
                // A few days before the end, so more are usually listed
                // before they get there.
                .onAppear { if day.id == moreAt, available > listed { showMore() } }
            }
            // Or at the end, if they got there first.
            if total != nil, available > listed {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Loading more…").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.s)
                .onAppear { showMore() }
            }
        }
    }

    private func summary(everything: Bool, available: Int) -> String {
        guard let total else { return slow ? "Loading…" : "" }
        if !everything, index == nil { return "Searching all \(total.formatted()) transactions…" }
        return available == 1 ? "1 transaction" : "\(available.formatted()) transactions"
    }

    /// No text, category or month: the newest of everything.
    private static func isEverything(_ query: TransactionQuery) -> Bool {
        Merchant.key(query.text).isEmpty && query.category == .any && query.month == nil
    }

    /// The end of the list has come into view: list more. Past the first
    /// page needs the whole history, which this starts reading if it isn't
    /// yet; until it's in, the list waits rather than asking again.
    private func showMore() {
        guard shown <= listed else { return }
        shown = listed + Self.morePage
    }

    /// Everything, newest first: the index once it's current, else the page.
    private var newest: [Core.Transaction] {
        if indexedAt == changes, let index { return index.transactions }
        // After a save, the fresh page, then the rest as the index had it
        // until it's read again, so a list scrolled deep doesn't shrink back
        // to the first page meanwhile.
        if let index { return TransactionSearch.splice(page, onto: index.transactions) }
        return page
    }

    private func show(_ found: [Core.Transaction]) {
        results = found
        resultsQuery = TransactionQuery(text: text, category: category, month: month)
        resultsAt = index != nil && indexedAt == changes ? changes : nil
        resultsVersion += 1
        regroup()
    }

    private var kinds: [String: CategoryKind] {
        Dictionary(
            kindRecords.compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            }, uniquingKeysWith: { first, _ in first })
    }

    /// The first `shown` results, to the end of the last one's day.
    private func regroup() {
        let listing = TransactionSearch.page(results, count: shown)
        days = TransactionSearch.byDay(Array(listing), kinds: kinds, transfers: matched)
        listed = listing.count
    }

    /// The newest page and the counts, on a context of its own. After a save
    /// it waits a moment first, so the several saves of one sync read once.
    private func loadPage() async {
        if changes > 0 {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
        }
        // Only a read still out after 300 ms says it's loading.
        let id = UUID()
        reading = id
        let flag = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, reading == id else { return }
            slow = true
            if total == nil { Perf.mark("loading.transactions") }
        }
        defer { flag.cancel(); if reading == id { slow = false } }
        let generation = TransactionsKept.generation
        guard let first = await Self.readPage(from: context.container, limit: Self.pageSize), !Task.isCancelled else { return }
        page = first.transactions
        #if DEBUG
            if !openedDebugTransaction, let merchant = DebugSupport.openTransactionName,
                let transaction = first.transactions.first(where: { $0.merchant == merchant })
            {
                selectedTransaction = transaction
                openedDebugTransaction = true
            }
        #endif
        if index == nil { matched = TransferMatch.toFile(in: first.transactions, kinds: kinds) }
        total = first.total
        monthRange = first.months
        known = first.known
        if index == nil { refiling.inUse = Set(first.transactions.compactMap(\.category)) }
        // Listed in the same update as the count, so the screen goes from
        // "Loading…" straight to the days, in one pass rather than two.
        let query = TransactionQuery(text: text, category: category, month: month)
        if Self.isEverything(query) {
            show(newest)
            // The filter this sets off would only list the same again.
            listedFor = Refilter(query: query, page: pageVersion + 1, index: indexVersion)
            if index == nil {
                TransactionsKept.keep(.init(first: first, matched: matched, days: days, listed: listed), generation: generation)
            }
        }
        pageVersion += 1
    }

    /// A search, a filter or scrolling to the end needs the whole history.
    /// Before the first page is in, `shown` is still the first page's size,
    /// so opening the screen doesn't count.
    private var needsIndexNow: Bool {
        !Self.isEverything(TransactionQuery(text: text, category: category, month: month)) || shown > Self.pageSize
    }

    /// The whole history as a search index. Unless a search or scrolling
    /// needs it now, it waits for the screen to settle, so opening the
    /// screen, or passing through it, never pays for 30,000 rows; a search
    /// started while it waits starts the read at once. A save rebuilds it, a
    /// moment later so the several saves of one sync read once.
    private func loadIndex() async {
        guard indexedAt != changes else { return }
        if index == nil {
            let settled = ContinuousClock.now + .seconds(1.5)
            while !needsIndexNow, ContinuousClock.now < settled, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
        } else {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        let at = changes
        guard let built = await Self.readIndex(from: context.container), !Task.isCancelled else { return }
        index = built
        indexedAt = at
        refiling.inUse = built.categories
        indexVersion += 1
        // After the index is in, so a search never waits on it; only the day
        // headers change.
        let found = await Self.matchTransfers(in: built.transactions, kinds: kinds)
        guard !Task.isCancelled, indexedAt == at else { return }
        matchedAt = at
        if found != matched { matched = found; regroup() }
    }

    private func refilter(_ query: TransactionQuery, everything: Bool) async {
        defer {
            if pageVersion > 0, !loaded {
                loaded = true
                Perf.mark("transactions.loaded")
            }
        }
        if everything {
            if listedFor != Refilter(query: query, page: pageVersion, index: indexVersion) { show(newest) }
            return
        }
        guard let index else {
            // Until the index is in, what's on hand; the summary says it's still searching.
            show(TransactionSearch.filter(page, query))
            return
        }
        if !query.text.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
        guard !Task.isCancelled else { return }
        let found = await Self.search(index, query)
        guard !Task.isCancelled else { return }
        show(found)
    }

    /// Only saves that touch transactions or category rules change this
    /// list; a save that doesn't say what it touched might have.
    nonisolated private static func touchesTransactions(_ note: Notification) -> Bool {
        guard let entities = ModelContext.savedEntityNames(in: note) else { return true }
        return entities.contains("TransactionRecord") || entities.contains("CategoryRuleRecord") || entities.contains("CategoryKindRecord")
    }
}

extension TransactionsView {
    nonisolated struct FirstPage: Sendable {
        var transactions: [Core.Transaction]
        var total: Int
        var months: [Month]
        var known: Set<String>
    }

    /// The newest `limit` transactions and the rest of the last one's day,
    /// how many there are, every month back to the oldest, and the category
    /// names rules, kinds and the plan know.
    @concurrent
    nonisolated static func readPage(from container: ModelContainer, limit: Int) async -> FirstPage? {
        let context = ModelContext(container)
        var newest = FetchDescriptor<TransactionRecord>(sortBy: [
            SortDescriptor(\.dayOrdinal, order: .reverse), SortDescriptor(\.externalID, order: .reverse)
        ])
        newest.fetchLimit = limit
        var records = (try? context.fetch(newest)) ?? []
        guard !Task.isCancelled else { return nil }
        // A page that stops partway through a day would show part of its net.
        if records.count == limit, let lastDay = records.last?.dayOrdinal {
            let wholeDay = FetchDescriptor<TransactionRecord>(
                predicate: #Predicate { $0.dayOrdinal == lastDay },
                sortBy: [SortDescriptor(\.externalID, order: .reverse)]
            )
            if let day = try? context.fetch(wholeDay) {
                records = records.filter { $0.dayOrdinal != lastDay } + day
            }
        }
        let transactions = records.map(\.transaction)
        let total = (try? context.fetchCount(FetchDescriptor<TransactionRecord>())) ?? transactions.count

        var oldest = FetchDescriptor<TransactionRecord>(sortBy: [SortDescriptor(\.dayOrdinal)])
        oldest.fetchLimit = 1
        oldest.propertiesToFetch = [\.dayOrdinal]
        var months: [Month] = []
        if let newestDay = transactions.first?.day, let first = (try? context.fetch(oldest))?.first?.dayOrdinal {
            let end = Month(Day(ordinal: first))
            var month = Month(newestDay)
            while month >= end {
                months.append(month)
                month = month.adding(-1)
            }
        }

        var known = Set(context.all(CategoryRuleRecord.self).map(\.category))
        known.formUnion(context.all(CategoryKindRecord.self).map(\.category))
        if let data = context.all(BudgetRecord.self).first?.planData,
            let plan = try? JSONDecoder().decode(BudgetPlan.self, from: data)
        {
            known.formUnion(plan.expected.keys)
            known.formUnion(plan.plannedIncome.keys)
            known.formUnion(plan.roles.keys)
        }
        return FirstPage(transactions: transactions, total: total, months: months, known: known)
    }

    /// Every transaction, sorted and keyed. Stops early when cancelled.
    @concurrent
    nonisolated static func readIndex(from container: ModelContainer) async -> TransactionIndex? {
        let context = ModelContext(container)
        let records = context.all(TransactionRecord.self)
        guard !Task.isCancelled else { return nil }
        let transactions = records.map(\.transaction)
        guard !Task.isCancelled else { return nil }
        return TransactionIndex(transactions)
    }

    /// Pairing all history is too slow for the main thread.
    @concurrent
    nonisolated static func matchTransfers(in transactions: [Core.Transaction], kinds: [String: CategoryKind]) async -> Set<UUID> {
        TransferMatch.toFile(in: transactions, kinds: kinds)
    }

    @concurrent
    nonisolated static func search(_ index: TransactionIndex, _ query: TransactionQuery) async -> [Core.Transaction] {
        index.filter(query)
    }
}

private struct Refilter: Equatable {
    let query: TransactionQuery
    let page: Int
    let index: Int
}

extension TransactionsView {
    /// Fills the search with what the search panel handed over, once.
    fileprivate func takeSearch() {
        guard let merchant = navigator.transactionSearch else { return }
        navigator.transactionSearch = nil
        category = .any
        month = nil
        text = merchant
    }
}

private struct RecentRequest: Equatable {
    let changes: Int
    let kinds: [String: CategoryKind]
}

extension TransactionsView {
    /// The summary's six months, read on their own: this month and the five
    /// before, plus a few days earlier so a transfer pair across the 1st still
    /// matches, as Spending reads it.
    fileprivate func summarizeRecent() async {
        let current = Month(Day(.now, in: .current))
        let from = current.adding(-TransactionSummaryPanel.monthsShown + 1).firstDay
        let start = from.ordinal - 7
        let kinds = kinds
        let summary = await Self.summarizeRecent(from: context.container, start: start, from: from, kinds: kinds)
        guard !Task.isCancelled else { return }
        recentFlow = summary
    }

    /// Read in a context of its own, so the main thread never builds the months' transactions.
    @concurrent nonisolated static func summarizeRecent(
        from container: ModelContainer, start: Int, from: Day,
        kinds: [String: CategoryKind]
    ) async -> TransactionSummary {
        let descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.dayOrdinal >= start })
        let transactions = ((try? ModelContext(container).fetch(descriptor)) ?? []).map(\.transaction)
        let transfers = TransferMatch.toFile(in: transactions, kinds: kinds)
        return TransactionSearch.summary(transactions.filter { $0.day >= from }, kinds: kinds, transfers: transfers)
    }
}

private struct SummaryRequest: Equatable {
    let query: TransactionQuery
    let results: Int
    let kinds: [String: CategoryKind]
    let transfers: Set<UUID>
    let changes: Int
    let matchedAt: Int?
}

private struct TransactionColumn: ViewModifier {
    let wide: Bool
    func body(content: Content) -> some View {
        if wide { content } else { content.screenColumn([]) }
    }
}

extension TransactionsView {
    @concurrent nonisolated static func summarize(
        _ transactions: [Core.Transaction], kinds: [String: CategoryKind],
        transfers: Set<UUID>
    ) async -> TransactionSummary {
        TransactionSearch.summary(transactions, kinds: kinds, transfers: transfers)
    }
}

/// Transactions' newest page and its days as last listed, kept across
/// visits (the whole history isn't). Cleared by any save the screen
/// itself would read again for; a read that started before that save
/// isn't kept.
@MainActor
private enum TransactionsKept {
    struct Page {
        let first: TransactionsView.FirstPage
        let matched: Set<UUID>
        let days: [TransactionDay]
        let listed: Int
    }

    private(set) static var page: Page?
    /// Bumped by each clear.
    private(set) static var generation = 0
    private static var observer: NSObjectProtocol?

    static func keep(_ page: Page, generation: Int) {
        guard generation == self.generation else { return }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
                guard touchesPage(note) else { return }
                MainActor.assumeIsolated { clear() }
            }
        }
        self.page = page
    }

    static func clear() {
        generation += 1
        page = nil
    }

    /// A save that doesn't say what it touched might have touched these.
    nonisolated private static func touchesPage(_ note: Notification) -> Bool {
        guard let entities = ModelContext.savedEntityNames(in: note) else { return true }
        return entities.contains("TransactionRecord") || entities.contains("CategoryRuleRecord") || entities.contains("CategoryKindRecord")
    }
}
