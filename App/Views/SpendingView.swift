import Core
import SwiftData
import SwiftUI

/// Where did it go, and how much is left?
struct SpendingView: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        SpendingScreen(month: $navigator.spendingMonth)
            .onDisappear { navigator.spendingMonth = Month(Day(.now, in: .current)) }
    }
}

private struct SpendingScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(Navigator.self) private var navigator
    @Query private var kindRecords: [CategoryKindRecord]
    @Query private var budgetRecords: [BudgetRecord]
    @Query private var payRecords: [PayProfileRecord]
    @Query(sort: \AccountRecord.createdAt) private var accountRecords: [AccountRecord]
    @Query(sort: \GoalRecord.createdAt) private var goalRecords: [GoalRecord]

    private var goalNames: [UUID: String] {
        Dictionary(goalRecords.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
    /// New transactions waiting for them to confirm their category, from any
    /// month, and any with no category at all.
    @Query(filter: #Predicate<TransactionRecord> { $0.reviewPending == true || $0.category == nil })
    private var toReview: [TransactionRecord]
    @Binding var month: Month
    /// The transactions on screen, read off the main thread for one month
    /// and view; nil until the first read is in. While the next read is
    /// under way (another month or view, or after a save) the last one stays
    /// on screen, drawn for its own month, so the screen never blanks.
    @State private var shown: SpendingRead?
    /// A read has taken long enough to say so; reads that come back quickly
    /// never flash a loading line.
    @State private var slow = false
    /// The read under way, so a superseded one's timer can't touch `slow`.
    @State private var reading = UUID()
    /// The paychecks that arrived, read off the main thread when deposits or pay change.
    @Environment(PayCache.self) private var payCache
    /// Nil until they're read with the current pay settings.
    private var paychecks: [PaycheckDeposit]? { payCache.paychecks(forProfile: payRecords.first?.profileData) }
    /// Bumped when a save touches transactions, so they're read again.
    @State private var changes = 0
    @State private var isEditingBudget = false
    @State private var budgetFromHistory = false
    @State private var isShowingCategories = false
    @State private var transfersFiled: Int?
    /// One-sided suggestions marked as not transfers, by external ID.
    @AppStorage("transfers.notTransfers") private var notTransfers = ""
    @State private var refiling = Refiling()
    @AppStorage(SpendingChartView.key) private var view = SpendingChartView.budget

    init(month: Binding<Month>) {
        _month = month
        // A read kept from an earlier visit is on screen from the first frame.
        let view = UserDefaults.standard.string(forKey: SpendingChartView.key).flatMap(SpendingChartView.init) ?? .budget
        _shown = State(initialValue: SpendingReads.kept(.init(month: month.wrappedValue, isBudget: view == .budget)))
    }
    /// Set once they switch view or month on this visit.
    @State private var switched = false

    var body: some View {
        let kinds = Dictionary(
            kindRecords.compactMap { record in
                CategoryKind(rawValue: record.kindRaw).map { (record.category, $0) }
            }, uniquingKeysWith: { first, _ in first })
        let schedule = budgetRecords.first?.schedule ?? BudgetSchedule(BudgetPlan(flexibleBudget: 0))
        // Loading until the paychecks are in too, so the plan never shows
        // without its income.
        let paychecks = self.paychecks ?? []
        let shown = self.paychecks == nil ? nil : self.shown
        let transactions = shown?.transactions ?? []
        // What's on screen is drawn for the month and view it was read for.
        let shownMonth = shown?.month ?? month
        // Two paychecks a month at the latest one that arrived.
        let pay = payRecords.first?.profile ?? PayProfile()
        let typed = schedule.plan(for: shownMonth)
        // The flexible budget is what's left once income is final.
        let plan = FlexBudget.balanced(Pay.planned(typed, month: shownMonth, profile: pay, paychecks: paychecks), kinds: kinds)
        let incomeNotes =
            !Pay.plansIncome(month: shownMonth, profile: pay, paychecks: paychecks)
            ? [:]
            : [
                pay.incomeCategory: Pay.incomeNote(month: shownMonth, profile: pay, paychecks: paychecks)
            ]
        let first = shownMonth.firstDay.ordinal, last = shownMonth.adding(1).firstDay.ordinal
        let thisMonth = transactions.filter { $0.day.ordinal >= first && $0.day.ordinal < last }
        let reviewing = toReview.count
        let uncategorized = toReview.filter { $0.category == nil }.count
        // Across both months read, so a pair that spans the 1st still matches.
        let matched = shown?.isBudget == true ? TransferMatch.toFile(in: transactions, kinds: kinds) : []
        let unfiledTransfers = matched.count
        // The budget reads matched pairs as filed: a card autopay and its
        // "payment thank you" aren't spending, filed or not.
        let budgeted = TransferMatch.asFiled(transactions, matched: matched)
        let settling = shown?.settling ?? [:]
        let dismissed = Set(notTransfers.split(separator: "\n").map(String.init))
        let oneSidedIDs = shown?.isBudget == true ? TransferMatch.likelyOneSided(in: transactions, kinds: kinds) : []
        let oneSided = thisMonth.filter { oneSidedIDs.contains($0.id) && !dismissed.contains($0.externalID) }
        let tidyUp = TidyUp(
            reviewing: reviewing, uncategorized: uncategorized, transfers: unfiledTransfers, oneSided: oneSided.count,
            choose: { navigator.screen = .review },
            fileTransfers: { findTransfers() },
            review: { navigator.screen = .review })

        ScrollView {
            // Lazy, so a month with hundreds of transactions under the budget
            // only builds the days on screen.
            LazyVStack(alignment: .leading, spacing: Spacing.l) {
                // Review remains available in Over time as well as the budget summary.
                if view != .budget, reviewing > 0 {
                    Button {
                        navigator.screen = .review
                    } label: {
                        Label(
                            reviewing == 1 ? "Review 1 transaction" : "Review \(reviewing.formatted()) transactions",
                            systemImage: "exclamationmark.triangle.fill")
                    }
                    .linkButton().tint(Palette.attention).font(Typeface.body)
                }
                if slow, let shown, shown.month != month || shown.isBudget != (view == .budget) {
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(month.name)… Showing \(shown.month.name) until it's ready.")
                            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    }
                    .onAppear { Perf.mark("loading.spending") }
                }

                // With a budget on screen these sit in its summary card; without
                // one (no budget yet, or the budget's read still on its way)
                // they keep a banner.
                if view == .budget, !tidyUp.isEmpty, !(shown?.isBudget == true && !schedule.isEmpty) {
                    TidyUpBanner(tidyUp: tidyUp)
                }

                if let shown {
                    if transactions.isEmpty && schedule.isEmpty {
                        Text("Import your Monarch transactions, or sync SimpleFIN, to see where your money goes.")
                            .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                            .card(padding: Spacing.l)
                    } else if shown.isBudget {
                        if schedule.isEmpty {
                            BudgetSetupPrompt(
                                fromHistory: {
                                    budgetFromHistory = true; isEditingBudget = true
                                },
                                fromScratch: {
                                    budgetFromHistory = false; isEditingBudget = true
                                }
                            )
                        } else {
                            BudgetSheetView(
                                sheet: FlexBudget.sheet(
                                    shownMonth, transactions: budgeted, kinds: kinds, plan: plan,
                                    settling: settling),
                                accounts: accountRecords.map(\.account),
                                month: shownMonth,
                                pace: FlexBudget.month(
                                    shownMonth, today: Day(.now, in: .current), transactions: budgeted,
                                    kinds: kinds, plan: plan),
                                schedule: schedule,
                                tidyUp: tidyUp,
                                incomeNotes: incomeNotes,
                                goalNames: goalNames,
                                save: { try? CompassStore(context: context).save($0) },
                                fileUnfiled: { navigator.screen = .review }
                            )
                        }
                        MonthTransactions(month: shownMonth, transactions: thisMonth, transfers: matched)
                    } else {
                        SpendingOverTime(
                            grid: Spending.monthlyByCategory(endingIn: shownMonth, transactions: transactions, kinds: kinds),
                            shownMonth: shownMonth, animates: switched)
                    }
                } else if slow || (self.shown != nil && paychecks == nil) {
                    // A slow read, or the read is in but the paychecks aren't yet.
                    Text("Loading…").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                        .onAppear { Perf.mark("loading.spending") }
                }
            }
            .screenColumn()
        }
        .background(Palette.canvas)
        .refiling(refiling)
        // The picker also offers categories only seen on these transactions.
        .onChange(of: Set(transactions.compactMap(\.category)), initial: true) { _, inUse in refiling.inUse = inUse }
        // Over time ends at this month, even with the budget a month or more ahead.
        .onChange(of: view) {
            switched = true
            if view != .budget { month = min(month, Month(Day(.now, in: .current))) }
        }
        // The chart animates only after a switch, never on opening Spending.
        .onChange(of: month) { switched = true }
        .task(id: SpendingRead.Request(month: month, isBudget: view == .budget, changes: changes)) {
            // Only a read still out after 300 ms says it's loading.
            let id = UUID()
            reading = id
            let flag = Task {
                try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled, reading == id { slow = true }
            }
            await withTaskCancellationHandler {
                await load(month: month, isBudget: view == .budget)
            } onCancel: {
                flag.cancel()
            }
            flag.cancel()
            if reading == id { slow = false }
            guard !Task.isCancelled else { return }
            // What they're likely to look at next, once they've paused on this:
            // the other view, and the month before. A step or leaving cancels it.
            try? await Task.sleep(for: .milliseconds(500))
            await prefetch(around: month, isBudget: view == .budget)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ModelContext.didSave)
                .filter(Self.touchesTransactions)
                .receive(on: DispatchQueue.main)
        ) { _ in
            // Cleared here too, so the read this sets off can't find a kept one first.
            SpendingReads.clear()
            changes += 1
        }
        .onChange(of: navigator.spendingAction, initial: true) { _, action in
            guard let action else { return }
            navigator.spendingAction = nil
            switch action {
            case .categories: isShowingCategories = true
            case .editBudget: budgetFromHistory = false; isEditingBudget = true
            case .fromHistory: budgetFromHistory = true; isEditingBudget = true
            }
        }
        .sheet(isPresented: $isEditingBudget) {
            BudgetEditor(
                schedule: schedule, month: month, fromHistory: budgetFromHistory,
                flexibleIsRemainder: Self.flexibleIsRemainder(in: month, paychecks: paychecks, context: context))
        }
        .sheet(isPresented: $isShowingCategories) { CategoriesSheet() }
        .alert("Transfers filed", isPresented: Binding(get: { transfersFiled != nil }, set: { if !$0 { transfersFiled = nil } })) {
            Button("OK") { transfersFiled = nil }
        } message: {
            Text(TransferHint.result(transfersFiled ?? 0))
        }
    }

    /// Income is planned in `month`, so its flexible budget is what's left.
    private static func flexibleIsRemainder(in month: Month, paychecks: [PaycheckDeposit], context: ModelContext) -> Bool {
        let store = CompassStore(context: context)
        guard let plan = try? store.budgetPlan(for: month, paychecks: paychecks), let kinds = try? store.kinds() else { return false }
        return plan.plannedIncome(kinds: kinds) > 0
    }

    /// Reads the month's transactions off the main thread. The budget needs
    /// two months (last month gives bills their usual day); Over time needs
    /// twelve.
    private func load(month: Month, isBudget: Bool) async {
        let key = SpendingReads.Key(month: month, isBudget: isBudget)
        let container = context.container
        if let kept = SpendingReads.kept(key, in: container) {
            shown = kept
        } else {
            let generation = SpendingReads.generation
            guard let read = await SpendingRead.read(key, from: container), !Task.isCancelled else { return }
            shown = read
            SpendingReads.keep(read, for: key, in: container, generation: generation)
        }
        Perf.mark("spending.loaded")
    }

    private func prefetch(around month: Month, isBudget: Bool) async {
        let container = context.container
        let now = Month(Day(.now, in: .current))
        let next = [
            SpendingReads.Key(month: isBudget ? min(month, now) : month, isBudget: !isBudget),
            SpendingReads.Key(month: month.adding(-1), isBudget: isBudget)
        ]
        for key in next where SpendingReads.kept(key, in: container) == nil {
            let generation = SpendingReads.generation
            guard let read = await SpendingRead.read(key, from: container), !Task.isCancelled else { return }
            SpendingReads.keep(read, for: key, in: container, generation: generation)
        }
    }

    /// Only saves that touch transactions change what's read; a save that
    /// doesn't say what it touched might have.
    nonisolated private static func touchesTransactions(_ note: Notification) -> Bool {
        guard let entities = ModelContext.savedEntityNames(in: note) else { return true }
        return entities.contains("TransactionRecord")
    }

    /// Across all history, once: matches are filed under Transfer.
    private func findTransfers() {
        transfersFiled = (try? CompassStore(context: context).fileTransfers()) ?? 0
    }
}

/// The transactions Spending shows, read for one month and view.
private nonisolated struct SpendingRead: Sendable {
    let month: Month
    /// The budget's read (two months, with merchants and accounts) rather
    /// than Over time's (twelve months, amounts and categories only).
    let isBudget: Bool
    let transactions: [Core.Transaction]
    /// What each move out of a goal's account paid for spending the goal
    /// covered, which the savings line doesn't count as taken back.
    var settling: [UUID: Decimal] = [:]

    /// What a read is for; a save asks for the same read again.
    struct Request: Equatable {
        let month: Month
        let isBudget: Bool
        let changes: Int
    }

    /// One month and view: a few months to a read, read side by side (making
    /// each row's model is most of the time, and contexts of their own can
    /// share it out). A read that failed shows nothing rather than
    /// "Loading…" for good, as the query it replaced did; nil if cancelled.
    static func read(_ key: SpendingReads.Key, from container: ModelContainer) async -> SpendingRead? {
        let months = key.isBudget ? 2 : 12, perRead = key.isBudget ? 1 : 3
        let parts = stride(from: months - 1, through: 0, by: -perRead).map { back in
            key.month.adding(-back).firstDay.ordinal..<key.month.adding(-back + perRead).firstDay.ordinal
        }
        let transactions = await transactions(from: container, in: parts, isBudget: key.isBudget)
        let settling = key.isBudget ? await settling(from: container) : [:]
        guard !Task.isCancelled else { return nil }
        return SpendingRead(month: key.month, isBudget: key.isBudget, transactions: transactions ?? [], settling: settling)
    }

    /// Across all history, and only once a goal has paid for something.
    @concurrent
    static func settling(from container: ModelContainer) async -> [UUID: Decimal] {
        GoalFunding.ledger(in: ModelContext(container)).settling
    }

    /// Over time never reads the account; one placeholder avoids faulting it in.
    static let unusedAccount = UUID()

    /// The transactions dated in each of `parts` (day ordinals), each part
    /// read at the same time on a context of its own; nil if cancelled.
    @concurrent
    static func transactions(from container: ModelContainer, in parts: [Range<Int>], isBudget: Bool) async -> [Core.Transaction]? {
        let read = await withTaskGroup(of: (Int, [Core.Transaction]?).self) { group in
            for (index, days) in parts.enumerated() {
                group.addTask { (index, transactions(from: container, days: days, isBudget: isBudget)) }
            }
            var read: [Int: [Core.Transaction]?] = [:]
            for await (index, transactions) in group { read[index] = transactions }
            return read
        }
        var all: [Core.Transaction] = []
        for index in parts.indices {
            guard let part = read[index] ?? nil else { return nil }
            all += part
        }
        return Task.isCancelled ? nil : all
    }

    /// The transactions dated in `days`, on a context of its own. Only the
    /// fields spending uses: reading each stored field costs time. The
    /// budget also spots transfers, which needs the account, and lists the
    /// month's transactions, which needs the merchant.
    private static func transactions(from container: ModelContainer, days: Range<Int>, isBudget: Bool) -> [Core.Transaction]? {
        let context = ModelContext(container)
        let first = days.lowerBound, last = days.upperBound
        var descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.dayOrdinal >= first && $0.dayOrdinal < last })
        descriptor.propertiesToFetch =
            isBudget
            ? [
                \.id, \.externalID, \.accountID, \.dayOrdinal, \.amount, \.merchant, \.statement, \.category,
                \.note, \.oneOff, \.reimbursable, \.reimbursableAmount, \.paidFromGoal, \.paidFromGoalAmount
            ]
            : [\.dayOrdinal, \.amount, \.category, \.reimbursable, \.reimbursableAmount, \.paidFromGoal, \.paidFromGoalAmount]
        guard let records = try? context.fetch(descriptor), !Task.isCancelled else { return nil }
        return records.map { record in
            record.withNotes(
                isBudget
                    ? Core.Transaction(
                        id: record.id, accountID: record.accountID, day: Day(ordinal: record.dayOrdinal),
                        amount: record.amount, merchant: record.merchant, statement: record.statement,
                        category: record.category, externalID: record.externalID)
                    : Core.Transaction(
                        accountID: unusedAccount, day: Day(ordinal: record.dayOrdinal), amount: record.amount,
                        merchant: "", category: record.category, externalID: ""))
        }
    }
}

/// Everything on the budget that needs a look: new transactions to confirm
/// (their guesses already count), and money that looks like it moved between
/// their own accounts (a matched pair already left out of the budget; a
/// one-sided one still counted until they confirm it).
struct TidyUp {
    let reviewing: Int
    let uncategorized: Int
    let transfers: Int
    let oneSided: Int
    let choose: () -> Void
    let fileTransfers: () -> Void
    let review: () -> Void

    var isEmpty: Bool { reviewing + transfers + oneSided == 0 }
}

/// The tidy-up rows on their own, for when there's no budget summary to hold them.
private struct TidyUpBanner: View {
    let tidyUp: TidyUp

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("To review").font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            // The setup prompt beside it has the screen's prominent button.
            TidyUpRows(tidyUp: tidyUp, reviewProminent: false)
        }
        .banner()
        .accessibilityElement(children: .contain)
    }
}

/// One row for each kind of thing to tidy up. Reviewing is the screen's one
/// prominent button: it's what they do most.
struct TidyUpRows: View {
    let tidyUp: TidyUp
    var reviewProminent = true

    var body: some View {
        let reviewing = tidyUp.reviewing, uncategorized = tidyUp.uncategorized
        let transfers = tidyUp.transfers, oneSided = tidyUp.oneSided
        VStack(alignment: .leading, spacing: Spacing.m) {
            if reviewing > 0 {
                TidyUpRow(
                    text: reviewing == 1 ? "1 transaction to check" : "\(reviewing.formatted()) transactions to check",
                    detail: uncategorized == 0
                        ? nil
                        : uncategorized == reviewing
                            ? (uncategorized == 1 ? "It needs a category." : "They need categories.")
                            : "\(uncategorized.formatted()) still \(uncategorized == 1 ? "needs a category" : "need categories").",
                    why: "Compass guessed the categories it could, and those already count in your budget.",
                    action: "Review",
                    actionLabel: reviewing == 1 ? "Review 1 transaction" : "Review \(reviewing.formatted()) transactions",
                    prominent: reviewProminent,
                    perform: tidyUp.choose)
            }
            if transfers > 0 {
                TidyUpRow(
                    text: transfers == 1
                        ? "1 looks like a transfer between your accounts"
                        : "\(transfers.formatted()) look like transfers between your accounts",
                    why: "Card payments and moves to savings aren't spending, so the budget already leaves them out. Filing them makes it stick.",
                    action: "File as Transfers",
                    actionLabel: transfers == 1
                        ? "File 1 transaction as a transfer"
                        : "File \(transfers.formatted()) transactions as transfers",
                    perform: tidyUp.fileTransfers)
            }
            if oneSided > 0 {
                TidyUpRow(
                    text: oneSided == 1
                        ? "1 looks like a transfer to an account Compass can't see"
                        : "\(oneSided.formatted()) look like transfers to accounts Compass can't see",
                    why: "Their bank descriptions read like card payments or moves between accounts. Check them before they leave your budget.",
                    action: "Review",
                    actionLabel: oneSided == 1
                        ? "Review 1 possible transfer to an account Compass can't see"
                        : "Review \(oneSided.formatted()) possible transfers to accounts Compass can't see",
                    perform: tidyUp.review)
            }
        }
    }
}

private struct TidyUpRow: View {
    let text: String
    /// A fact to act on, under the title ("23 still need categories").
    var detail: String?
    /// Why it matters, as a hover tip on the title rather than a paragraph
    /// (less to read when the screen is fine).
    var why: String?
    let action: String
    /// What the button does and to what, for VoiceOver ("Review" alone says neither).
    let actionLabel: String
    var prominent = false
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                // Amber, as everything that needs a look, so it doesn't blend in.
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention)
                        .accessibilityHidden(true)
                    Text(text).font(Typeface.body.weight(.medium)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(why ?? "")
                .accessibilityHint(why ?? "")
                .font(Typeface.body)
                Spacer(minLength: Spacing.s)
                Group {
                    if prominent {
                        Button(action, action: perform).buttonStyle(.borderedProminent)
                    } else {
                        Button(action, action: perform)
                    }
                }
                .font(Typeface.body)
                .accessibilityLabel(actionLabel)
                // Voice Control still answers to what the button says.
                .accessibilityInputLabels([action])
            }
            if let detail {
                Text(detail).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What filing transfers across their history says when it's done.
enum TransferHint {
    static func result(_ count: Int) -> String {
        switch count {
        case 0: "No new transfers between your accounts turned up."
        case 1: "1 transaction is now filed under Transfer, so it no longer counts as spending."
        default: "\(count) transactions across your history are now filed under Transfer, so they no longer count as spending."
        }
    }
}

private struct BudgetSetupPrompt: View {
    let fromHistory: () -> Void
    let fromScratch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Image(systemName: "chart.pie").font(.system(size: 26 * TextSize.current.scale)).foregroundStyle(Palette.needle)
            Text("Set your monthly budget").font(Typeface.figure).foregroundStyle(Palette.ink)
            Text(
                "Bills like rent and internet are fixed: Compass checks them off as they're paid, and their total tells you what an emergency fund should cover. Everything else shares one flexible amount, so you can see how much is left for the month."
            )
            .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.m) {
                Button("Set up from my history", action: fromHistory).buttonStyle(.borderedProminent)
                Button("Start from scratch", action: fromScratch)
            }
            Text(
                "From your history, steady monthly charges become fixed bills at their usual amount, and the flexible budget starts at your last three months' average. You review it before saving."
            )
            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: Spacing.xl)
    }
}

struct MonthStepper: View {
    @Binding var month: Month
    /// The furthest month it steps to.
    let latest: Month
    var compact = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button("Previous Month", systemImage: "chevron.left") { month = month.adding(-1) }
                .labelStyle(.iconOnly).linkButton()
            Text(compact ? month.firstDay.startDate(in: .current).formatted(.dateTime.month(.abbreviated).year()) : month.name)
                .font(compact ? Typeface.detail : Typeface.body).monospacedDigit().foregroundStyle(Palette.ink)
                .frame(minWidth: compact ? nil : 120 * TextSize.current.scale)
                .help(month.name)
            Button("Next Month", systemImage: "chevron.right") { month = month.adding(1) }
                .labelStyle(.iconOnly).linkButton()
                .disabled(month >= latest)
        }
    }
}

extension Month {
    var name: String {
        Day(year: year, month: month, day: 1).startDate(in: .current).formatted(.dateTime.month(.wide).year())
    }
}

/// Spending's two views: the budget, and spending over time.
enum SpendingChartView: String, CaseIterable {
    case budget, overTime

    static let key = "spending.view"

    var title: String {
        switch self {
        case .budget: "Budget"
        case .overTime: "Over time"
        }
    }
}

/// Spending's recent reads, kept across visits so coming back, switching
/// view or stepping a month shows at once. Any save that touches
/// transactions, goals or category kinds clears them (the next read is fresh); a read that
/// started before that save isn't kept.
@MainActor
private enum SpendingReads {
    struct Key: Hashable, Sendable {
        let month: Month
        let isBudget: Bool
    }

    /// Bumped by each clear.
    private(set) static var generation = 0
    private static var reads: [Key: SpendingRead] = [:]
    /// Least recently used first, so only the last few are kept.
    private static var order: [Key] = []
    private static var container: ObjectIdentifier?
    private static var observer: NSObjectProtocol?

    /// The kept read, from whichever store was last read (the app has one).
    static func kept(_ key: Key) -> SpendingRead? { reads[key] }

    /// Counts as a use, so the reads they keep going back to are the ones kept.
    static func kept(_ key: Key, in container: ModelContainer) -> SpendingRead? {
        guard self.container == ObjectIdentifier(container), let read = reads[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return read
    }

    static func keep(_ read: SpendingRead, for key: Key, in container: ModelContainer, generation: Int) {
        guard generation == self.generation else { return }
        if self.container != ObjectIdentifier(container) { clear(); self.container = ObjectIdentifier(container) }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
                guard touchesReads(note) else { return }
                MainActor.assumeIsolated { clear() }
            }
        }
        reads[key] = read
        order.removeAll { $0 == key }
        order.append(key)
        // The one on screen and its neighbours: enough for stepping about, little to hold.
        while order.count > 6 { reads[order.removeFirst()] = nil }
    }

    static func clear() {
        generation += 1
        reads = [:]
        order = []
    }

    /// A save that doesn't say what it touched might have touched these.
    nonisolated private static func touchesReads(_ note: Notification) -> Bool {
        guard let entities = ModelContext.savedEntityNames(in: note) else { return true }
        // Goals and category kinds decide what a goal's savings line settles.
        return entities.contains("TransactionRecord") || entities.contains("GoalRecord") || entities.contains("CategoryKindRecord")
    }
}
